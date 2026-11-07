import XCTest
@testable import S5Core

final class ConfigTests: XCTestCase {
    private func prefix(_ localPath: String, _ s3Prefix: String?) -> String {
        FolderConfig(localPath: localPath, s3Prefix: s3Prefix, exclude: nil).normalizedPrefix
    }

    func testNormalizedPrefix() {
        XCTAssertEqual(prefix("~/Documents/Factures", "factures"), "factures/")
        XCTAssertEqual(prefix("~/x", "/a/b/"), "a/b/")
        XCTAssertEqual(prefix("~/x", " a/b "), "a/b/")
        XCTAssertEqual(prefix("~/x", "a//b"), "a//b/")
        XCTAssertEqual(prefix("~/x", "été"), "été/")
    }

    func testEmptyPrefixMeansBucketRoot() {
        XCTAssertEqual(prefix("~/x", ""), "")
        XCTAssertEqual(prefix("~/x", "/"), "")
        XCTAssertEqual(prefix("~/x", "  "), "")
    }

    func testDefaultPrefixIsFolderName() {
        XCTAssertEqual(prefix("~/Documents/Factures", nil), "Factures/")
        XCTAssertEqual(prefix("/Volumes/Disque/Photos/", nil), "Photos/")
    }

    func testDecodingAppliesDefaults() throws {
        let json = #"{"bucket": "b", "folders": [{"localPath": "~/a"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.awsProfile, "default")
        XCTAssertNil(config.region)
        XCTAssertFalse(config.deleteRemote)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertNil(config.schedule.intervalMinutes)
        XCTAssertEqual(config.folders.first?.normalizedPrefix, "a/")
    }

    func testDecodingAccessKeyOnlyHasNoProfile() throws {
        let json = #"{"bucket": "b", "accessKeyId": " AKIAEXAMPLE ", "folders": [{"localPath": "~/a"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.awsProfile)
        XCTAssertEqual(config.staticKey, StaticKeyConfig(accessKeyId: "AKIAEXAMPLE", sessionToken: nil, plaintextSecret: nil))
    }

    func testDecodingProfileAndAccessKey() throws {
        let json = #"{"bucket": "b", "awsProfile": "perso", "accessKeyId": "AKIAEXAMPLE", "sessionToken": "t", "#
            + #""secretAccessKey": "s", "folders": [{"localPath": "~/a"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.awsProfile, "perso")
        XCTAssertEqual(config.staticKey, StaticKeyConfig(accessKeyId: "AKIAEXAMPLE", sessionToken: "t", plaintextSecret: "s"))
    }

    func testEmptyAccessKeyIsIgnored() throws {
        let json = #"{"bucket": "b", "accessKeyId": "", "folders": [{"localPath": "~/a"}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.awsProfile, "default")
        XCTAssertNil(config.staticKey)
    }

    func testValidationRejectsSecretWithoutAccessKey() {
        let json = #"{"bucket": "b", "secretAccessKey": "s", "folders": [{"localPath": "~/a"}]}"#
        XCTAssertThrowsError(try ConfigStore.decode(Data(json.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("accessKeyId"), error.localizedDescription)
        }
    }

    func testDecodingRequiresBucket() {
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: Data(#"{"folders": []}"#.utf8)))
    }

    func testExampleConfigDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config.example.json")
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(config.schedule.dailyTimes, ["02:00"])
        XCTAssertEqual(config.folders.first?.exclude, ["*.tmp", "node_modules"])
        XCTAssertEqual(config.awsProfile, "default")
        XCTAssertEqual(config.accessKeyId, "AKIAIOSFODNN7EXAMPLE")
    }

    func testLoadFromPathReadsGivenFileWithoutTemplate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.json")
        try Data(#"{"awsProfile": "perso", "bucket": "b", "folders": [{"localPath": "~/a"}]}"#.utf8).write(to: url)
        XCTAssertEqual(try ConfigStore.load(from: url).awsProfile, "perso")

        let missing = dir.appendingPathComponent("absent.json")
        XCTAssertThrowsError(try ConfigStore.load(from: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testLegacyDirectoryIsCopiedOnceIntoTheNewOne() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("MyDropbox")
        let current = root.appendingPathComponent("SimpleSyncS3")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("config.json"))
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("state.json"))

        XCTAssertTrue(ConfigStore.migrate(from: legacy, to: current))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("config.json")), "{}")
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("state.json").path))
        XCTAssertTrue(fm.fileExists(atPath: legacy.appendingPathComponent("config.json").path), "l'ancien dossier reste intact")

        // Une fois le nouveau dossier créé, il n'est plus jamais écrasé.
        try Data("{\"bucket\": \"b\"}".utf8).write(to: legacy.appendingPathComponent("config.json"))
        XCTAssertFalse(ConfigStore.migrate(from: legacy, to: current))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("config.json")), "{}")
    }

    func testNoLegacyDirectoryMeansNoMigration() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(ConfigStore.migrate(from: root.appendingPathComponent("MyDropbox"),
                                           to: root.appendingPathComponent("SimpleSyncS3")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testStateStoreUsesGivenURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SyncStateStore(url: url)
        store.record(bucket: "b", key: "k", size: 3, mtime: 1.5)
        store.save()
        XCTAssertEqual(SyncStateStore(url: url).entry(bucket: "b", key: "k")?.mtime, 1.5)
    }
}
