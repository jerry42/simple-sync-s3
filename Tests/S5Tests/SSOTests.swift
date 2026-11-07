import XCTest
@testable import S5Core

/// Faux transport HTTP : réponses rejouées dans l'ordre, requêtes enregistrées.
private final class FakeTransport: HTTPTransport {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func body(_ index: Int) -> [String: Any] {
        guard let data = requests[index].httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

final class SSOTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var dir: URL!

    private let sessionConfig = """
    [profile perso]
    sso_session = my-sso
    sso_account_id = 123456789012
    sso_role_name = Sync+Role
    region = eu-west-3

    [sso-session my-sso]
    sso_start_url = https://d-123.awsapps.com/start
    sso_region = eu-west-1
    sso_registration_scopes = sso:account:access

    [profile ancien]
    sso_start_url = https://d-123.awsapps.com/start
    sso_region = us-east-1
    sso_account_id = 210987654321
    sso_role_name = Lecture

    [profile cles]
    aws_access_key_id = AKIDCONFIG
    aws_secret_access_key = secret-config

    [profile processus]
    credential_process = /bin/echo nope

    [profile role]
    role_arn = arn:aws:iam::123:role/x
    source_profile = cles
    """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sso-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sessionConfig.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var cacheDir: URL { dir.appendingPathComponent("sso/cache") }

    private func profile(_ name: String = "perso") throws -> SSOProfile {
        let config = INIFile.parse(text: sessionConfig)
        return try XCTUnwrap(SSOProfile(name: name, section: config["profile \(name)"] ?? [:], config: config))
    }

    private func client(_ transport: FakeTransport, profile name: String = "perso") throws -> SSOClient {
        var c = SSOClient(profile: try profile(name), cacheDirectory: cacheDir, transport: transport)
        c.now = { [now] in now }
        c.sleep = { _ in }
        return c
    }

    private func writeToken(_ token: SSOToken, profile name: String = "perso") throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try token.encoded().write(to: cacheDir.appendingPathComponent(try profile(name).cacheFileName))
    }

    private func readToken(profile name: String = "perso") throws -> SSOToken {
        try SSOToken.decode(Data(contentsOf: cacheDir.appendingPathComponent(try profile(name).cacheFileName)))
    }

    private func token(expiresIn: TimeInterval, refresh: String? = "rt-1") -> SSOToken {
        SSOToken(startUrl: "https://d-123.awsapps.com/start", region: "eu-west-1", accessToken: "at-1",
                 expiresAt: now.addingTimeInterval(expiresIn), clientId: "cid", clientSecret: "csecret",
                 registrationExpiresAt: now.addingTimeInterval(86_400), refreshToken: refresh)
    }

    private let roleReply = FakeTransport.Reply(status: 200, body: """
    {"roleCredentials":{"accessKeyId":"ASIAROLE","secretAccessKey":"role-secret",
     "sessionToken":"role-token","expiration":1800003600000}}
    """)

    // MARK: - Profils

    func testSessionProfileParsing() throws {
        let p = try profile()
        XCTAssertEqual(p.startURL, "https://d-123.awsapps.com/start")
        XCTAssertEqual(p.ssoRegion, "eu-west-1")
        XCTAssertEqual(p.accountId, "123456789012")
        XCTAssertEqual(p.roleName, "Sync+Role")
        XCTAssertEqual(p.sessionName, "my-sso")
        XCTAssertEqual(p.scopes, ["sso:account:access"])
        // Même nom de fichier que l'AWS CLI : SHA-1 du nom de session.
        XCTAssertEqual(p.cacheFileName, "0ad374308c5a4e22f723adf10145eafad7c4031c.json")
    }

    func testLegacyProfileParsing() throws {
        let p = try profile("ancien")
        XCTAssertNil(p.sessionName)
        XCTAssertEqual(p.ssoRegion, "us-east-1")
        // Ancien format : SHA-1 de l'URL de départ.
        XCTAssertEqual(p.cacheFileName, "2b829a45f04c9828cb45b7d092d8e4aa30818393.json")
    }

    func testNonSSOProfileIsNil() throws {
        let config = INIFile.parse(text: sessionConfig)
        XCTAssertNil(try SSOProfile(name: "cles", section: config["profile cles"]!, config: config))
    }

    func testIncompleteProfiles() {
        let missingSession = INIFile.parse(text: "[profile x]\nsso_session = absente\nsso_account_id = 1\nsso_role_name = r")
        XCTAssertThrowsError(try SSOProfile(name: "x", section: missingSession["profile x"]!, config: missingSession)) {
            XCTAssertTrue($0.localizedDescription.contains("sso-session absente"), $0.localizedDescription)
        }
        let missingRole = INIFile.parse(text: "[profile x]\nsso_start_url = https://a\nsso_region = eu-west-1\nsso_account_id = 1")
        XCTAssertThrowsError(try SSOProfile(name: "x", section: missingRole["profile x"]!, config: missingRole)) {
            XCTAssertTrue($0.localizedDescription.contains("sso_role_name"), $0.localizedDescription)
        }
    }

    // MARK: - Cache

    func testTokenDatesInCLIFormats() throws {
        let json = """
        {"startUrl":"https://a","region":"eu-west-1","accessToken":"t","expiresAt":"2026-11-06T16:00:00UTC"}
        """
        let t = try SSOToken.decode(Data(json.utf8))
        XCTAssertEqual(t.expiresAt, SSOToken.parseDate("2026-11-06T16:00:00Z"))
        XCTAssertNil(t.refreshToken)
        XCTAssertNotNil(SSOToken.parseDate("2026-11-06T16:00:00.123Z"))
        let encoded = String(decoding: try t.encoded(), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"expiresAt\" : \"2026-11-06T16:00:00Z\""), encoded)
    }

    // MARK: - Identifiants

    func testValidCachedTokenGetsRoleCredentials() throws {
        try writeToken(token(expiresIn: 3600))
        let transport = FakeTransport([roleReply])
        let creds = try client(transport).roleCredentials()

        XCTAssertEqual(creds.accessKeyId, "ASIAROLE")
        XCTAssertEqual(creds.sessionToken, "role-token")
        XCTAssertEqual(creds.expiration, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(transport.requests.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.url?.host, "portal.sso.eu-west-1.amazonaws.com")
        XCTAssertEqual(request.url?.path, "/federation/credentials")
        // « + » encodé, sinon le serveur le lit comme une espace.
        XCTAssertEqual(request.url?.query, "account_id=123456789012&role_name=Sync%2BRole")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-sso_bearer_token"), "at-1")
    }

    func testExpiredTokenIsRefreshedAndSaved() throws {
        try writeToken(token(expiresIn: -10))
        let transport = FakeTransport([
            .init(status: 200, body: #"{"accessToken":"at-2","expiresIn":28800,"refreshToken":"rt-2","tokenType":"Bearer"}"#),
            roleReply,
        ])
        _ = try client(transport).roleCredentials()

        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://oidc.eu-west-1.amazonaws.com/token")
        XCTAssertEqual(transport.body(0)["grantType"] as? String, "refresh_token")
        XCTAssertEqual(transport.body(0)["refreshToken"] as? String, "rt-1")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "x-amz-sso_bearer_token"), "at-2")
        let saved = try readToken()
        XCTAssertEqual(saved.accessToken, "at-2")
        XCTAssertEqual(saved.refreshToken, "rt-2")
        XCTAssertEqual(saved.expiresAt, now.addingTimeInterval(28800))
        XCTAssertEqual(saved.clientId, "cid")
    }

    func testRejectedRefreshRequiresLogin() throws {
        try writeToken(token(expiresIn: -10))
        let transport = FakeTransport([.init(status: 400, body: #"{"error":"invalid_grant"}"#)])
        XCTAssertThrowsError(try client(transport).roleCredentials()) { error in
            guard case SSOError.loginRequired("perso") = error else { return XCTFail("\(error)") }
        }
    }

    func testRefreshNetworkErrorIsNotALoginRequest() throws {
        try writeToken(token(expiresIn: -10))
        XCTAssertThrowsError(try client(FakeTransport([])).roleCredentials()) { error in
            XCTAssertTrue(error is URLError, "\(error)")
        }
    }

    func testExpiredTokenWithoutRefreshRequiresLogin() throws {
        try writeToken(token(expiresIn: -10, refresh: nil))
        XCTAssertThrowsError(try client(FakeTransport([])).roleCredentials()) { error in
            guard case SSOError.loginRequired = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingCacheRequiresLogin() throws {
        let transport = FakeTransport([])
        XCTAssertThrowsError(try client(transport).roleCredentials()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Sign In to AWS"), error.localizedDescription)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnauthorizedRoleCallRequiresLogin() throws {
        try writeToken(token(expiresIn: 3600))
        let transport = FakeTransport([.init(status: 401, body: #"{"message":"Session token not found or invalid"}"#)])
        XCTAssertThrowsError(try client(transport).roleCredentials()) { error in
            guard case SSOError.loginRequired = error else { return XCTFail("\(error)") }
        }
    }

    func testForbiddenRoleCallReportsMessage() throws {
        try writeToken(token(expiresIn: 3600))
        let transport = FakeTransport([.init(status: 403, body: #"{"message":"No access"}"#)])
        XCTAssertThrowsError(try client(transport).roleCredentials()) { error in
            XCTAssertTrue(error.localizedDescription.contains("403"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("No access"), error.localizedDescription)
        }
    }

    // MARK: - Connexion

    private let registerReply = FakeTransport.Reply(status: 200, body: """
    {"clientId":"new-cid","clientSecret":"new-secret","clientIdIssuedAt":1800000000,"clientSecretExpiresAt":1807776000}
    """)
    private let authorizationReply = FakeTransport.Reply(status: 200, body: """
    {"deviceCode":"dev-1","userCode":"ABCD-EFGH","verificationUri":"https://device.sso.eu-west-1.amazonaws.com/",
     "verificationUriComplete":"https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH","expiresIn":600,"interval":1}
    """)

    func testDeviceLoginFlow() throws {
        let transport = FakeTransport([
            registerReply, authorizationReply,
            .init(status: 400, body: #"{"error":"authorization_pending"}"#),
            .init(status: 400, body: "", headers: ["x-amzn-ErrorType": "SlowDownException:http://internal"]),
            .init(status: 200, body: #"{"accessToken":"at-new","expiresIn":28800,"refreshToken":"rt-new"}"#),
        ])
        var opened: SSODeviceAuthorization?
        try client(transport).login(open: { opened = $0 }, isCancelled: { false })

        XCTAssertEqual(opened?.userCode, "ABCD-EFGH")
        XCTAssertEqual(opened?.verificationURL.absoluteString,
                       "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH")
        XCTAssertEqual(transport.requests.map { $0.url!.path },
                       ["/client/register", "/device_authorization", "/token", "/token", "/token"])
        XCTAssertEqual(transport.body(0)["scopes"] as? [String], ["sso:account:access"])
        XCTAssertEqual(transport.body(0)["grantTypes"] as? [String],
                       ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"])
        XCTAssertEqual(transport.body(1)["startUrl"] as? String, "https://d-123.awsapps.com/start")
        XCTAssertEqual(transport.body(2)["deviceCode"] as? String, "dev-1")

        let saved = try readToken()
        XCTAssertEqual(saved.accessToken, "at-new")
        XCTAssertEqual(saved.refreshToken, "rt-new")
        XCTAssertEqual(saved.clientId, "new-cid")
        XCTAssertEqual(saved.registrationExpiresAt, Date(timeIntervalSince1970: 1_807_776_000))
        XCTAssertEqual(saved.region, "eu-west-1")
        let mode = try FileManager.default.attributesOfItem(
            atPath: cacheDir.appendingPathComponent(try profile().cacheFileName).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLegacyLoginRegistersWithoutScopes() throws {
        let transport = FakeTransport([
            registerReply, authorizationReply,
            .init(status: 200, body: #"{"accessToken":"at-new","expiresIn":3600}"#),
        ])
        try client(transport, profile: "ancien").login(open: { _ in }, isCancelled: { false })
        XCTAssertNil(transport.body(0)["scopes"])
        XCTAssertEqual(transport.requests[0].url?.host, "oidc.us-east-1.amazonaws.com")
        XCTAssertNil(try readToken(profile: "ancien").refreshToken)
    }

    func testLoginDeniedInBrowser() throws {
        let transport = FakeTransport([
            registerReply, authorizationReply,
            .init(status: 400, body: #"{"error":"access_denied"}"#),
        ])
        XCTAssertThrowsError(try client(transport).login(open: { _ in }, isCancelled: { false })) { error in
            XCTAssertTrue(error.localizedDescription.contains("denied"), error.localizedDescription)
        }
    }

    func testLoginCancelled() throws {
        let transport = FakeTransport([registerReply, authorizationReply])
        XCTAssertThrowsError(try client(transport).login(open: { _ in }, isCancelled: { true })) { error in
            guard case SSOError.cancelled = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testErrorCodeNormalization() {
        let response = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(SSOClient.errorCode(Data(#"{"error":"authorization_pending"}"#.utf8), response), "authorizationpending")
        XCTAssertEqual(SSOClient.errorCode(Data(#"{"__type":"com.amazonaws#ExpiredTokenException"}"#.utf8), response), "expiredtoken")
    }

    // MARK: - Résolution du profil (et sandbox)

    private func profileCredentials(sandboxed: Bool = false, authorized: Bool = true,
                                    transport: FakeTransport = FakeTransport([])) -> ProfileCredentials {
        var p = ProfileCredentials()
        p.awsDir = dir
        p.environment = [:]
        p.sandboxed = sandboxed
        p.awsDirAuthorized = { authorized }
        p.transport = transport
        return p
    }

    func testProfileUsesNativeSSO() throws {
        try writeToken(token(expiresIn: 3600))
        let creds = try profileCredentials(transport: FakeTransport([roleReply])).load(profile: "perso")
        XCTAssertEqual(creds.accessKeyId, "ASIAROLE")
    }

    func testSandboxedProfileWithStaticKeysWorks() throws {
        let creds = try profileCredentials(sandboxed: true).load(profile: "cles")
        XCTAssertEqual(creds.accessKeyId, "AKIDCONFIG")
    }

    func testSandboxWithoutAWSDirAccess() {
        XCTAssertThrowsError(try profileCredentials(sandboxed: true, authorized: false).load(profile: "cles")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Grant Access"), error.localizedDescription)
        }
    }

    func testSandboxRefusesCredentialProcess() {
        XCTAssertThrowsError(try profileCredentials(sandboxed: true).load(profile: "processus")) { error in
            XCTAssertTrue(error.localizedDescription.contains("credential_process is not available"), error.localizedDescription)
        }
    }

    func testSandboxRefusesAssumeRole() {
        XCTAssertThrowsError(try profileCredentials(sandboxed: true).load(profile: "role")) { error in
            XCTAssertTrue(error.localizedDescription.contains("role_arn"), error.localizedDescription)
        }
    }
}
