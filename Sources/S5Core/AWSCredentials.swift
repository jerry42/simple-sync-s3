import Foundation

struct AWSCredentials {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let expiration: Date?
}

enum AWSCredentialError: LocalizedError {
    case noCredentials(String)
    case processFailed(String)
    case notConfigured
    case unavailable([String])
    case awsDirNotAuthorized
    case unavailableInSandbox(String, String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let profile):
            if Sandbox.isActive {
                return "Aucun identifiant AWS trouvé pour le profil « \(profile) » (ni clés, ni SSO)."
            }
            return "Aucun identifiant AWS trouvé pour le profil « \(profile) » (ni clés, ni SSO, ni credential_process, ni AWS CLI)."
        case .awsDirNotAuthorized:
            return "Accès à ~/.aws non autorisé (sandbox) : menu « Autoriser l'accès… »."
        case .unavailableInSandbox(let profile, let feature):
            return "Profil « \(profile) » : \(feature) indisponible dans la version sandbox "
                + "(utilise un profil à clés ou SSO, ou une clé d'accès dans config.json)."
        case .processFailed(let message):
            return "Échec de récupération des identifiants AWS : \(message)"
        case .notConfigured:
            return "Ni profil AWS ni clé d'accès dans config.json."
        case .unavailable(let reasons):
            return "Identifiants AWS indisponibles : " + reasons.joined(separator: " ; ")
        }
    }
}

/// Lecture minimale des fichiers INI d'AWS (~/.aws/config et ~/.aws/credentials).
enum INIFile {
    static func parse(_ url: URL) -> [String: [String: String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text: text)
    }

    static func parse(text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                current = name
                if result[name] == nil { result[name] = [:] }
                continue
            }
            guard let section = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[section]?[key] = value
        }
        return result
    }
}

/// Lecture des identifiants d'un profil AWS nommé (~/.aws), dans cet ordre :
/// 1. clés statiques (credentials ou config)
/// 2. IAM Identity Center (SSO), en natif : jeton du cache partagé avec l'AWS CLI, puis GetRoleCredentials
/// 3. credential_process du profil (hors sandbox)
/// 4. `aws configure export-credentials` (assume-role, etc. si l'AWS CLI v2 est installée ; hors sandbox)
///
/// Sous sandbox, ~/.aws n'est lisible qu'après autorisation de l'utilisateur (signet, voir `AccessGrants`),
/// et aucun programme externe ne peut être lancé.
struct ProfileCredentials {
    var awsDir: URL = AWSDirectory.url
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var sandboxed: Bool = Sandbox.isActive
    /// Sous sandbox : l'utilisateur a autorisé l'accès à ~/.aws.
    var awsDirAuthorized: () -> Bool = { AccessGrants.shared.covers(AWSDirectory.path) }
    var transport: HTTPTransport = URLSessionTransport()

    static func load(profile: String) throws -> AWSCredentials {
        try ProfileCredentials().load(profile: profile)
    }

    /// Région déclarée dans ~/.aws/config pour ce profil.
    static func region(profile: String) -> String? {
        let credentials = ProfileCredentials()
        return credentials.configSection(profile, in: INIFile.parse(credentials.configFile))["region"]
    }

    private var configFile: URL {
        if let path = environment["AWS_CONFIG_FILE"] {
            return URL(fileURLWithPath: RealHome.expand(path))
        }
        return awsDir.appendingPathComponent("config")
    }

    private var credentialsFile: URL {
        if let path = environment["AWS_SHARED_CREDENTIALS_FILE"] {
            return URL(fileURLWithPath: RealHome.expand(path))
        }
        return awsDir.appendingPathComponent("credentials")
    }

    private func configSection(_ profile: String, in config: [String: [String: String]]) -> [String: String] {
        let name = profile == "default" ? "default" : "profile \(profile)"
        return config[name] ?? config[profile] ?? [:]
    }

    /// Sous sandbox, échoue avec un message clair tant que ~/.aws n'a pas été autorisé.
    func checkAccess() throws {
        if sandboxed && !awsDirAuthorized() { throw AWSCredentialError.awsDirNotAuthorized }
    }

    /// Profils déclarés dans ~/.aws/config et ~/.aws/credentials, triés (« default » en tête).
    func profileNames() -> [String] {
        var names = Set<String>()
        for section in INIFile.parse(configFile).keys {
            if section == "default" { names.insert(section) }
            else if section.hasPrefix("profile ") {
                names.insert(String(section.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces))
            }
        }
        names.formUnion(INIFile.parse(credentialsFile).keys)
        names.remove("")
        return names.sorted { a, b in
            if a == "default" || b == "default" { return a == "default" && b != "default" }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    func ssoProfile(_ profile: String) throws -> SSOProfile? {
        let config = INIFile.parse(configFile)
        return try SSOProfile(name: profile, section: configSection(profile, in: config), config: config)
    }

    func ssoClient(_ profile: SSOProfile) -> SSOClient {
        SSOClient(profile: profile, cacheDirectory: awsDir.appendingPathComponent("sso/cache", isDirectory: true),
                  transport: transport)
    }

    func load(profile: String) throws -> AWSCredentials {
        try checkAccess()
        let config = INIFile.parse(configFile)
        let section = configSection(profile, in: config)
        let creds = INIFile.parse(credentialsFile)[profile] ?? [:]
        let merged = section.merging(creds) { _, fromCredentials in fromCredentials }

        if let ak = merged["aws_access_key_id"], let sk = merged["aws_secret_access_key"] {
            return AWSCredentials(accessKeyId: ak, secretAccessKey: sk,
                                  sessionToken: merged["aws_session_token"], expiration: nil)
        }
        if let sso = try SSOProfile(name: profile, section: section, config: config) {
            return try ssoClient(sso).roleCredentials()
        }
        if let process = merged["credential_process"] {
            guard !sandboxed else { throw AWSCredentialError.unavailableInSandbox(profile, "credential_process") }
            return try runCredentialProcess(["/bin/sh", "-c", process])
        }
        if sandboxed {
            if merged["role_arn"] != nil { throw AWSCredentialError.unavailableInSandbox(profile, "assume-role (role_arn)") }
            throw AWSCredentialError.noCredentials(profile)
        }
        guard let aws = findAWSCLI() else {
            throw AWSCredentialError.noCredentials(profile)
        }
        return try runCredentialProcess([aws, "configure", "export-credentials",
                                         "--profile", profile, "--format", "process"])
    }

    private func findAWSCLI() -> String? {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func runCredentialProcess(_ args: [String]) throws -> AWSCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        // Une app lancée depuis le Finder a un PATH minimal.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AWSCredentialError.processFailed(message.isEmpty ? "code \(process.terminationStatus)" : message)
        }

        struct ProcessOutput: Decodable {
            let AccessKeyId: String
            let SecretAccessKey: String
            let SessionToken: String?
            let Expiration: String?
        }
        let output: ProcessOutput
        do {
            output = try JSONDecoder().decode(ProcessOutput.self, from: data)
        } catch {
            throw AWSCredentialError.processFailed("réponse JSON illisible")
        }
        return AWSCredentials(accessKeyId: output.AccessKeyId,
                              secretAccessKey: output.SecretAccessKey,
                              sessionToken: output.SessionToken,
                              expiration: output.Expiration.flatMap(Self.parseDate))
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// Clé d'accès déclarée dans config.json ; la clé secrète est dans le trousseau
/// (ou, en dernier recours, en clair dans config.json).
struct StaticKeyConfig: Equatable {
    let accessKeyId: String
    let sessionToken: String?
    let plaintextSecret: String?
}

enum CredentialSource: Equatable {
    case profile(String)
    case keychain
    case configFile
}

/// Profils AWS disponibles (fenêtre de réglages). Vide si ~/.aws est illisible (sandbox sans autorisation).
public enum AWSProfiles {
    public static func names() -> [String] {
        let credentials = ProfileCredentials()
        guard (try? credentials.checkAccess()) != nil else { return [] }
        return credentials.profileNames()
    }
}

public enum AccessKey {
    /// Forme abrégée pour le journal : « AKIA…WXYZ ».
    public static func masked(_ accessKeyId: String) -> String {
        guard accessKeyId.count > 8 else { return "…" }
        return "\(accessKeyId.prefix(4))…\(accessKeyId.suffix(4))"
    }
}

/// Résout les identifiants AWS :
/// 1. le profil nommé, s'il est configuré ;
/// 2. si le profil est absent ou n'aboutit pas (~/.aws illisible depuis une sandbox, AWS CLI absente…),
///    la clé d'accès de config.json avec la clé secrète du trousseau, puis celle écrite en clair dans config.json.
/// Aucun secret n'est jamais écrit dans le journal.
final class AWSCredentialProvider {
    let profile: String?
    let staticKey: StaticKeyConfig?
    private let secretStore: SecretStore
    private let loadProfile: (String) throws -> AWSCredentials
    private let log: (String) -> Void
    private var cached: AWSCredentials?
    private let lock = NSLock()

    init(profile: String?,
         staticKey: StaticKeyConfig? = nil,
         secretStore: SecretStore = KeychainSecretStore(),
         loadProfile: @escaping (String) throws -> AWSCredentials = ProfileCredentials.load(profile:),
         log: @escaping (String) -> Void = Log.info) {
        self.profile = profile
        self.staticKey = staticKey
        self.secretStore = secretStore
        self.loadProfile = loadProfile
        self.log = log
    }

    convenience init(config: AppConfig) {
        self.init(profile: config.awsProfile, staticKey: config.staticKey)
    }

    /// Région déclarée dans ~/.aws/config pour le profil.
    func region() -> String? {
        profile.flatMap(ProfileCredentials.region(profile:))
    }

    func credentials() throws -> AWSCredentials {
        lock.lock()
        defer { lock.unlock() }
        if let c = cached {
            if let exp = c.expiration {
                if exp.timeIntervalSinceNow > 300 { return c }
            } else {
                return c
            }
        }
        let fresh = try resolve().credentials
        cached = fresh
        return fresh
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    func resolve() throws -> (credentials: AWSCredentials, source: CredentialSource) {
        var failures: [String] = []
        if let profile {
            do {
                let credentials = try loadProfile(profile)
                log("Identifiants AWS : profil « \(profile) »")
                return (credentials, .profile(profile))
            } catch {
                guard staticKey != nil else {
                    throw AWSCredentialError.unavailable([
                        "profil « \(profile) » : \(error.localizedDescription)",
                        "pour utiliser une clé d'accès à la place, ajoute \"accessKeyId\" dans config.json",
                    ])
                }
                failures.append("profil « \(profile) » : \(error.localizedDescription)")
                log("Profil AWS « \(profile) » indisponible (\(error.localizedDescription)), "
                    + "bascule sur la clé d'accès de config.json")
            }
        }
        guard let key = staticKey else { throw AWSCredentialError.notConfigured }
        let masked = AccessKey.masked(key.accessKeyId)

        do {
            if let secret = try secretStore.secret(for: key.accessKeyId) {
                log("Identifiants AWS : clé d'accès \(masked), clé secrète du trousseau")
                return (AWSCredentials(accessKeyId: key.accessKeyId, secretAccessKey: secret,
                                       sessionToken: key.sessionToken, expiration: nil), .keychain)
            }
        } catch {
            failures.append("trousseau : \(error.localizedDescription)")
        }

        if let secret = key.plaintextSecret {
            log("Identifiants AWS : clé d'accès \(masked), clé secrète lue dans config.json (en clair). "
                + "Plus sûr : le trousseau (menu « Enregistrer la clé secrète AWS… »), "
                + "puis retirer \"secretAccessKey\" de config.json.")
            return (AWSCredentials(accessKeyId: key.accessKeyId, secretAccessKey: secret,
                                   sessionToken: key.sessionToken, expiration: nil), .configFile)
        }

        failures.append("aucune clé secrète pour la clé d'accès \(masked) "
                        + "(menu « Enregistrer la clé secrète AWS… »)")
        throw AWSCredentialError.unavailable(failures)
    }
}
