import Foundation
import CryptoKit

enum SSOError: LocalizedError {
    case incompleteProfile(String, missing: String)
    case loginRequired(String)
    case loginFailed(String)
    case http(Int, String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .incompleteProfile(let profile, let missing):
            return "Profil SSO « \(profile) » incomplet dans ~/.aws/config : \(missing) manquant."
        case .loginRequired(let profile):
            return "Connexion IAM Identity Center requise pour le profil « \(profile) » "
                + "(menu « Se connecter à AWS… », ou s5-sync --login)."
        case .loginFailed(let message):
            return "Connexion IAM Identity Center impossible : \(message)"
        case .http(let code, let message):
            return "IAM Identity Center HTTP \(code) – \(message.prefix(300))"
        case .cancelled:
            return "Connexion IAM Identity Center annulée."
        }
    }
}

/// Profil IAM Identity Center (SSO) lu dans ~/.aws/config, au format `sso_session` ou à l'ancien format.
struct SSOProfile: Equatable {
    let name: String
    let startURL: String
    let ssoRegion: String
    let accountId: String
    let roleName: String
    /// Section `[sso-session …]` ; nil pour l'ancien format (pas de jeton de rafraîchissement).
    let sessionName: String?
    let scopes: [String]

    /// Fichier de cache partagé avec l'AWS CLI dans ~/.aws/sso/cache : SHA-1 du nom de session,
    /// ou de l'URL de départ pour l'ancien format.
    var cacheFileName: String {
        let digest = Insecure.SHA1.hash(data: Data((sessionName ?? startURL).utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// nil si le profil n'utilise pas SSO.
    init?(name: String, section: [String: String], config: [String: [String: String]]) throws {
        let source: [String: String]
        if let session = section["sso_session"] {
            guard let s = config["sso-session \(session)"] else {
                throw SSOError.incompleteProfile(name, missing: "section [sso-session \(session)]")
            }
            source = s
            sessionName = session
            let rawScopes = s["sso_registration_scopes"] ?? "sso:account:access"
            scopes = rawScopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else if section["sso_start_url"] != nil {
            source = section
            sessionName = nil
            scopes = []
        } else {
            return nil
        }
        func value(_ dict: [String: String], _ key: String) throws -> String {
            guard let v = dict[key], !v.isEmpty else { throw SSOError.incompleteProfile(name, missing: key) }
            return v
        }
        self.name = name
        startURL = try value(source, "sso_start_url")
        ssoRegion = try value(source, "sso_region")
        accountId = try value(section, "sso_account_id")
        roleName = try value(section, "sso_role_name")
    }
}

/// Jeton SSO au format du cache de l'AWS CLI (~/.aws/sso/cache/<sha1>.json), lu et écrit tel quel
/// pour que `aws sso login` et Simple Sync S3 partagent la même session.
struct SSOToken: Codable, Equatable {
    var startUrl: String
    var region: String
    var accessToken: String
    var expiresAt: Date
    var clientId: String?
    var clientSecret: String?
    var registrationExpiresAt: Date?
    var refreshToken: String?

    static func decode(_ data: Data) throws -> SSOToken {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: text))
            }
            return date
        }
        return try decoder.decode(SSOToken.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.formatDate(date))
        }
        return try encoder.encode(self)
    }

    /// L'AWS CLI écrit « 2026-11-06T16:00:00Z » (anciennes versions : « …UTC »).
    static func parseDate(_ text: String) -> Date? {
        let normalized = text.hasSuffix("UTC") ? String(text.dropLast(3)) + "Z" : text
        let f = ISO8601DateFormatter()
        if let d = f.date(from: normalized) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: normalized)
    }

    static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// Demande d'autorisation d'appareil : l'utilisateur valide `userCode` sur `verificationURL`.
public struct SSODeviceAuthorization: Sendable {
    public let userCode: String
    public let verificationURL: URL
}

/// Client IAM Identity Center écrit à la main (SSO-OIDC + portail SSO), sans dépendance :
/// - jeton lu dans le cache de l'AWS CLI, rafraîchi avec le refresh token s'il a expiré ;
/// - connexion par autorisation d'appareil (navigateur) quand il n'y a plus de jeton utilisable ;
/// - identifiants temporaires du rôle via `GetRoleCredentials`.
struct SSOClient {
    static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"

    let profile: SSOProfile
    let cacheDirectory: URL
    let transport: HTTPTransport
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    private var cacheURL: URL { cacheDirectory.appendingPathComponent(profile.cacheFileName) }
    private var oidcBase: String { "https://oidc.\(profile.ssoRegion).amazonaws.com" }

    // MARK: - Identifiants

    func roleCredentials() throws -> AWSCredentials {
        let token = try validToken()
        let query = "account_id=\(SigV4.uriEncode(profile.accountId))&role_name=\(SigV4.uriEncode(profile.roleName))"
        guard let url = URL(string: "https://portal.sso.\(profile.ssoRegion).amazonaws.com/federation/credentials?\(query)")
        else { throw SSOError.loginFailed("URL du portail invalide") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(token.accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try transport.send(request)
        if response.statusCode == 401 { throw SSOError.loginRequired(profile.name) }
        guard (200..<300).contains(response.statusCode) else {
            throw SSOError.http(response.statusCode, Self.message(data))
        }
        struct Output: Decodable {
            struct Role: Decodable {
                let accessKeyId: String
                let secretAccessKey: String
                let sessionToken: String
                let expiration: Int64
            }
            let roleCredentials: Role
        }
        guard let role = try? JSONDecoder().decode(Output.self, from: data).roleCredentials else {
            throw SSOError.loginFailed("réponse GetRoleCredentials illisible")
        }
        return AWSCredentials(accessKeyId: role.accessKeyId, secretAccessKey: role.secretAccessKey,
                              sessionToken: role.sessionToken,
                              expiration: Date(timeIntervalSince1970: TimeInterval(role.expiration) / 1000))
    }

    /// Jeton du cache s'il est encore valable, sinon rafraîchi. `loginRequired` si aucun n'est utilisable.
    func validToken() throws -> SSOToken {
        guard let data = try? Data(contentsOf: cacheURL), let token = try? SSOToken.decode(data),
              token.startUrl == profile.startURL else {
            throw SSOError.loginRequired(profile.name)
        }
        if token.expiresAt.timeIntervalSince(now()) > 60 { return token }

        guard let refreshToken = token.refreshToken, let clientId = token.clientId,
              let clientSecret = token.clientSecret,
              (token.registrationExpiresAt ?? .distantFuture).timeIntervalSince(now()) > 60 else {
            throw SSOError.loginRequired(profile.name)
        }
        let (data2, response) = try postJSON("/token", [
            "clientId": clientId, "clientSecret": clientSecret,
            "grantType": "refresh_token", "refreshToken": refreshToken,
        ])
        // Refresh token refusé ou expiré : il faut se reconnecter. Les erreurs réseau remontent telles quelles.
        if (400..<500).contains(response.statusCode) { throw SSOError.loginRequired(profile.name) }
        guard (200..<300).contains(response.statusCode) else {
            throw SSOError.http(response.statusCode, Self.message(data2))
        }
        let created = try decode(CreateTokenOutput.self, data2, "CreateToken")
        var fresh = token
        fresh.accessToken = created.accessToken
        fresh.expiresAt = now().addingTimeInterval(TimeInterval(created.expiresIn))
        fresh.refreshToken = created.refreshToken ?? refreshToken
        try save(fresh)
        Log.info("Jeton IAM Identity Center rafraîchi (profil « \(profile.name) »)")
        return fresh
    }

    // MARK: - Connexion par autorisation d'appareil

    /// Enregistre un client, demande une autorisation d'appareil, appelle `open` pour que l'utilisateur
    /// la valide dans son navigateur, puis attend le jeton et l'écrit dans le cache.
    func login(open: (SSODeviceAuthorization) -> Void, isCancelled: () -> Bool) throws {
        var registerBody: [String: Any] = ["clientName": "SimpleSyncS3", "clientType": "public"]
        if profile.sessionName != nil {
            registerBody["scopes"] = profile.scopes
            registerBody["grantTypes"] = [Self.deviceCodeGrant, "refresh_token"]
        }
        let (regData, regResponse) = try postJSON("/client/register", registerBody)
        try check(regResponse, regData)
        struct RegisterOutput: Decodable {
            let clientId: String
            let clientSecret: String
            let clientSecretExpiresAt: Int64?
        }
        let client = try decode(RegisterOutput.self, regData, "RegisterClient")

        let (authData, authResponse) = try postJSON("/device_authorization", [
            "clientId": client.clientId, "clientSecret": client.clientSecret, "startUrl": profile.startURL,
        ])
        try check(authResponse, authData)
        struct AuthorizationOutput: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationUri: String
            let verificationUriComplete: String?
            let expiresIn: Int
            let interval: Int?
        }
        let auth = try decode(AuthorizationOutput.self, authData, "StartDeviceAuthorization")
        guard let url = URL(string: auth.verificationUriComplete ?? auth.verificationUri) else {
            throw SSOError.loginFailed("URL de validation invalide")
        }
        open(SSODeviceAuthorization(userCode: auth.userCode, verificationURL: url))

        var interval = max(auth.interval ?? 5, 1)
        let deadline = now().addingTimeInterval(TimeInterval(auth.expiresIn))
        while true {
            for _ in 0..<interval {
                if isCancelled() { throw SSOError.cancelled }
                sleep(1)
            }
            if isCancelled() { throw SSOError.cancelled }
            if now() > deadline { throw SSOError.loginFailed("code expiré avant validation") }

            let (data, response) = try postJSON("/token", [
                "clientId": client.clientId, "clientSecret": client.clientSecret,
                "grantType": Self.deviceCodeGrant, "deviceCode": auth.deviceCode,
            ])
            if (200..<300).contains(response.statusCode) {
                let created = try decode(CreateTokenOutput.self, data, "CreateToken")
                try save(SSOToken(
                    startUrl: profile.startURL, region: profile.ssoRegion, accessToken: created.accessToken,
                    expiresAt: now().addingTimeInterval(TimeInterval(created.expiresIn)),
                    clientId: client.clientId, clientSecret: client.clientSecret,
                    registrationExpiresAt: client.clientSecretExpiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    refreshToken: created.refreshToken))
                Log.info("Connecté à IAM Identity Center (profil « \(profile.name) »)")
                return
            }
            switch Self.errorCode(data, response) {
            case "authorizationpending": continue
            case "slowdown": interval += 5
            case "expiredtoken": throw SSOError.loginFailed("code expiré avant validation")
            case "accessdenied": throw SSOError.loginFailed("autorisation refusée dans le navigateur")
            default: throw SSOError.http(response.statusCode, Self.message(data))
            }
        }
    }

    // MARK: - Helpers

    private struct CreateTokenOutput: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
    }

    private func postJSON(_ path: String, _ body: [String: Any]) throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: oidcBase + path) else { throw SSOError.loginFailed("URL OIDC invalide") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try transport.send(request)
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw SSOError.http(response.statusCode, Self.message(data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ operation: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SSOError.loginFailed("réponse \(operation) illisible")
        }
    }

    private func save(_ token: SSOToken) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try token.encoded().write(to: cacheURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }

    /// Code d'erreur OIDC normalisé : « authorization_pending » et « AuthorizationPendingException »
    /// donnent tous deux « authorizationpending ».
    static func errorCode(_ data: Data, _ response: HTTPURLResponse) -> String {
        var raw = ""
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = (object["error"] as? String) ?? (object["__type"] as? String) ?? ""
        }
        if raw.isEmpty, let header = response.value(forHTTPHeaderField: "x-amzn-ErrorType") {
            raw = String(header.split(separator: ":").first ?? "")
        }
        if let hash = raw.lastIndex(of: "#") { raw = String(raw[raw.index(after: hash)...]) }
        var code = raw.lowercased().replacingOccurrences(of: "_", with: "")
        if code.hasSuffix("exception") { code = String(code.dropLast("exception".count)) }
        return code
    }

    static func message(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error_description", "message", "Message", "error"] {
                if let m = object[key] as? String, !m.isEmpty { return m }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Point d'entrée pour l'interface et l'outil en ligne de commande.
public enum SSOLogin {
    /// Indique si le profil est configuré pour IAM Identity Center (faux si ~/.aws est illisible).
    public static func isSSOProfile(_ profile: String) -> Bool {
        (try? ProfileCredentials().ssoProfile(profile)) != nil
    }

    /// Connexion par le navigateur. Bloquant (jusqu'à la validation, l'expiration du code ou l'annulation) :
    /// à appeler hors du thread principal.
    public static func login(profile: String,
                             open: (SSODeviceAuthorization) -> Void,
                             isCancelled: () -> Bool = { false }) throws {
        let credentials = ProfileCredentials()
        try credentials.checkAccess()
        guard let sso = try credentials.ssoProfile(profile) else {
            throw SSOError.loginFailed("le profil « \(profile) » n'est pas un profil IAM Identity Center")
        }
        try credentials.ssoClient(sso).login(open: open, isCancelled: isCancelled)
    }
}
