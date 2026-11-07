import XCTest
@testable import S5Core

private struct FakeSecretStore: SecretStore {
    var secrets: [String: String] = [:]
    var failure: Error?

    func secret(for accessKeyId: String) throws -> String? {
        if let failure { throw failure }
        return secrets[accessKeyId]
    }
}

private struct ProfileFailure: LocalizedError {
    var errorDescription: String? { "~/.aws illisible" }
}

final class CredentialResolutionTests: XCTestCase {
    private let accessKeyId = "AKIAIOSFODNN7EXAMPLE"
    private let keychainSecret = "secret-du-trousseau"
    private let plainSecret = "secret-en-clair"
    private let profileCredentials = AWSCredentials(accessKeyId: "AKIDPROFILE", secretAccessKey: "secret-du-profil",
                                                    sessionToken: nil, expiration: nil)
    private var logs: [String] = []
    private var profileCalls = 0

    override func tearDown() {
        // Aucun secret ne doit apparaître dans le journal.
        for line in logs {
            for secret in [keychainSecret, plainSecret, profileCredentials.secretAccessKey] {
                XCTAssertFalse(line.contains(secret), line)
            }
        }
        super.tearDown()
    }

    private func provider(profile: String?, profileWorks: Bool = true,
                          staticKey: StaticKeyConfig? = nil,
                          store: FakeSecretStore = FakeSecretStore()) -> AWSCredentialProvider {
        AWSCredentialProvider(profile: profile, staticKey: staticKey, secretStore: store,
                              loadProfile: { [unowned self] _ in
                                  profileCalls += 1
                                  if profileWorks { return profileCredentials }
                                  throw ProfileFailure()
                              },
                              log: { [unowned self] in logs.append($0) })
    }

    private func key(token: String? = nil, plain: String? = nil) -> StaticKeyConfig {
        StaticKeyConfig(accessKeyId: accessKeyId, sessionToken: token, plaintextSecret: plain)
    }

    private var storeWithSecret: FakeSecretStore { FakeSecretStore(secrets: [accessKeyId: keychainSecret]) }

    func testProfileWinsWhenItWorks() throws {
        let result = try provider(profile: "perso", staticKey: key(), store: storeWithSecret).resolve()
        XCTAssertEqual(result.source, .profile("perso"))
        XCTAssertEqual(result.credentials.accessKeyId, "AKIDPROFILE")
        XCTAssertTrue(logs.contains { $0.contains("profil « perso »") })
    }

    func testFallsBackToKeychainWhenProfileFails() throws {
        let result = try provider(profile: "perso", profileWorks: false,
                                  staticKey: key(token: "jeton"), store: storeWithSecret).resolve()
        XCTAssertEqual(result.source, .keychain)
        XCTAssertEqual(result.credentials.accessKeyId, accessKeyId)
        XCTAssertEqual(result.credentials.secretAccessKey, keychainSecret)
        XCTAssertEqual(result.credentials.sessionToken, "jeton")
        XCTAssertTrue(logs.contains { $0.contains("~/.aws illisible") && $0.contains("bascule") })
        XCTAssertTrue(logs.contains { $0.contains("AKIA…MPLE") && $0.contains("trousseau") })
    }

    func testAccessKeyAloneSkipsProfile() throws {
        let result = try provider(profile: nil, staticKey: key(), store: storeWithSecret).resolve()
        XCTAssertEqual(result.source, .keychain)
        XCTAssertEqual(profileCalls, 0)
    }

    func testKeychainBeatsPlaintextSecret() throws {
        let result = try provider(profile: nil, staticKey: key(plain: plainSecret), store: storeWithSecret).resolve()
        XCTAssertEqual(result.source, .keychain)
        XCTAssertEqual(result.credentials.secretAccessKey, keychainSecret)
    }

    func testPlaintextSecretIsLastResortWithWarning() throws {
        let result = try provider(profile: "perso", profileWorks: false, staticKey: key(plain: plainSecret)).resolve()
        XCTAssertEqual(result.source, .configFile)
        XCTAssertEqual(result.credentials.secretAccessKey, plainSecret)
        XCTAssertTrue(logs.contains { $0.contains("en clair") })
    }

    func testAccessKeyAndSecretFromConfigJSON() throws {
        let json = #"{"accessKeyId":"AKIAIOSFODNN7EXAMPLE","secretAccessKey":"secret-en-clair","region":"eu-west-3","bucket":"b","folders":[{"localPath":"~/a"}]}"#
        let config = try ConfigStore.decode(Data(json.utf8))
        XCTAssertNil(config.awsProfile)
        let result = try provider(profile: config.awsProfile, staticKey: config.staticKey).resolve()
        XCTAssertEqual(result.source, .configFile)
        XCTAssertEqual(result.credentials.accessKeyId, accessKeyId)
        XCTAssertEqual(result.credentials.secretAccessKey, plainSecret)
        XCTAssertEqual(profileCalls, 0)
    }

    func testKeychainErrorFallsBackToPlaintext() throws {
        let store = FakeSecretStore(failure: KeychainError(status: errSecInteractionNotAllowed))
        let result = try provider(profile: nil, staticKey: key(plain: plainSecret), store: store).resolve()
        XCTAssertEqual(result.source, .configFile)
    }

    func testProfileFailureWithoutAccessKeyExplainsAlternative() {
        XCTAssertThrowsError(try provider(profile: "perso", profileWorks: false).resolve()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("~/.aws illisible"), message)
            XCTAssertTrue(message.contains("accessKeyId"), message)
        }
    }

    func testNoSecretAnywhereIsAClearError() {
        XCTAssertThrowsError(try provider(profile: "perso", profileWorks: false, staticKey: key()).resolve()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("profil « perso »"), message)
            XCTAssertTrue(message.contains("AKIA…MPLE"), message)
            XCTAssertTrue(message.contains("Enregistrer la clé secrète AWS"), message)
        }
    }

    func testKeychainErrorIsReportedWhenNothingElseWorks() {
        let store = FakeSecretStore(failure: KeychainError(status: errSecInteractionNotAllowed))
        XCTAssertThrowsError(try provider(profile: nil, staticKey: key(), store: store).resolve()) { error in
            XCTAssertTrue(error.localizedDescription.contains("trousseau"), error.localizedDescription)
        }
    }

    func testNothingConfigured() {
        XCTAssertThrowsError(try provider(profile: nil).resolve()) { error in
            XCTAssertEqual(error.localizedDescription, AWSCredentialError.notConfigured.localizedDescription)
        }
    }

    func testCredentialsAreCached() throws {
        let p = provider(profile: "perso")
        _ = try p.credentials()
        _ = try p.credentials()
        XCTAssertEqual(profileCalls, 1)
    }

    func testMaskedAccessKey() {
        XCTAssertEqual(AccessKey.masked("AKIAIOSFODNN7EXAMPLE"), "AKIA…MPLE")
        XCTAssertEqual(AccessKey.masked("short"), "…")
        XCTAssertEqual(AccessKey.masked(""), "…")
    }
}
