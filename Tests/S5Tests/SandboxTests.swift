import XCTest
@testable import S5Core

final class SandboxTests: XCTestCase {
    func testTestsRunUnsandboxed() {
        XCTAssertFalse(Sandbox.isActive)
    }

    func testRealHomeExpansion() {
        XCTAssertEqual(RealHome.expand("~/Documents/été", home: "/Users/moi"), "/Users/moi/Documents/été")
        XCTAssertEqual(RealHome.expand("~", home: "/Users/moi"), "/Users/moi")
        XCTAssertEqual(RealHome.expand("/tmp/x", home: "/Users/moi"), "/tmp/x")
        XCTAssertEqual(RealHome.expand("~autre/x", home: "/Users/moi"), "~autre/x")
        XCTAssertFalse(RealHome.path.contains("/Library/Containers/"))
    }

    func testCovers() {
        let roots = ["/Users/moi/Documents", "/Users/moi/.aws/"]
        XCTAssertTrue(AccessGrants.covers("/Users/moi/Documents", roots: roots))
        XCTAssertTrue(AccessGrants.covers("/Users/moi/Documents/Factures/", roots: roots))
        XCTAssertTrue(AccessGrants.covers("/Users/moi/.aws", roots: roots))
        XCTAssertFalse(AccessGrants.covers("/Users/moi/DocumentsPerso", roots: roots))
        XCTAssertFalse(AccessGrants.covers("/Users/moi/Documents/../Desktop", roots: roots))
        XCTAssertFalse(AccessGrants.covers("/Users/moi", roots: roots))
        // NFD (disque) contre NFC (config.json).
        XCTAssertTrue(AccessGrants.covers("/Users/moi/E\u{301}te\u{301}/x", roots: ["/Users/moi/\u{C9}t\u{E9}"]))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testGrantPersistsAcrossLaunches() throws {
        let dir = try tempDir()
        let folder = dir.appendingPathComponent("Factures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("bookmarks.json")

        let first = AccessGrants(storeURL: store)
        try first.grant(folder)
        XCTAssertTrue(first.covers(folder.appendingPathComponent("2026/a.pdf").path))

        let second = AccessGrants(storeURL: store)
        XCTAssertFalse(second.covers(folder.path))
        XCTAssertEqual(second.activateAll(), [])
        XCTAssertTrue(second.covers(folder.path))
    }

    func testUnreadableBookmarkIsReported() throws {
        let dir = try tempDir()
        let store = dir.appendingPathComponent("bookmarks.json")
        try JSONEncoder().encode(["/nulle/part": Data("pas un signet".utf8)]).write(to: store)
        let failures = AccessGrants(storeURL: store).activateAll()
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures[0].contains("/nulle/part"))
    }

    func testMissingAccessForConfig() throws {
        let dir = try tempDir()
        let json = """
        {"awsProfile":"perso","bucket":"b","folders":[{"localPath":"\(dir.path)/A"},{"localPath":"\(dir.path)/B"},
         {"localPath":"\(dir.path)/A"}]}
        """
        let config = try ConfigStore.decode(Data(json.utf8))
        let grants = AccessGrants(storeURL: dir.appendingPathComponent("bookmarks.json"))
        XCTAssertEqual(grants.missing(for: config), [AWSDirectory.path, "\(dir.path)/A", "\(dir.path)/B"])

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("A"), withIntermediateDirectories: true)
        try grants.grant(dir.appendingPathComponent("A"))
        XCTAssertEqual(grants.missing(for: config), [AWSDirectory.path, "\(dir.path)/B"])

        let keyOnly = try ConfigStore.decode(Data(#"{"accessKeyId":"AKID","bucket":"b","folders":[{"localPath":"/x"}]}"#.utf8))
        XCTAssertEqual(grants.missing(for: keyOnly), ["/x"])
    }
}
