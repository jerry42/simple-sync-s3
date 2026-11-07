import XCTest
@testable import S5Core

final class ProfileNamesTests: XCTestCase {
    func testListsProfilesFromBothFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        [profile work]
        sso_session = ug
        [sso-session ug]
        sso_region = eu-west-3
        [default]
        region = eu-west-3
        [profile perso10]
        [profile perso2]
        """.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        [default]
        aws_access_key_id = AKIDEXAMPLE
        [backup]
        aws_access_key_id = AKIDEXAMPLE
        """.write(to: dir.appendingPathComponent("credentials"), atomically: true, encoding: .utf8)

        let names = ProfileCredentials(awsDir: dir, environment: [:], sandboxed: false).profileNames()
        XCTAssertEqual(names, ["default", "backup", "perso2", "perso10", "work"])
    }
}
