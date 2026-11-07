import XCTest
@testable import S5Core

final class ConfigDraftTests: XCTestCase {
    private let full = """
    {
      "awsProfile": "perso",
      "sessionToken": "jeton",
      "region": "eu-west-3",
      "bucket": "b",
      "deleteRemote": true,
      "futureOption": {"a": [1, 2.5, null]},
      "schedule": {"intervalMinutes": 30, "dailyTimes": ["02:00", "13:30"], "syncOnLaunch": true, "jitter": 5},
      "folders": [
        {"localPath": "~/Documents/Factures", "s3Prefix": "factures", "exclude": ["*.tmp", "node_modules/"], "note": "x"},
        {"localPath": "~/Racine", "s3Prefix": ""},
        {"localPath": "~/Défaut"}
      ]
    }
    """

    private func roundTrip(_ draft: ConfigDraft) throws -> [String: JSONValue] {
        try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: draft.encoded()).object)
    }

    func testReadsFields() throws {
        let draft = try ConfigDraft(data: Data(full.utf8))
        XCTAssertEqual(draft.awsProfile, "perso")
        XCTAssertEqual(draft.accessKeyId, "")
        XCTAssertEqual(draft.region, "eu-west-3")
        XCTAssertTrue(draft.deleteRemote)
        XCTAssertFalse(draft.launchAtLogin)
        XCTAssertTrue(draft.syncOnLaunch)
        XCTAssertEqual(draft.intervalMinutes, 30)
        XCTAssertEqual(draft.dailyTimes, "02:00, 13:30")
        XCTAssertEqual(draft.folders.map(\.localPath), ["~/Documents/Factures", "~/Racine", "~/Défaut"])
        XCTAssertEqual(draft.folders.map(\.s3Prefix), ["factures", "", nil])
        XCTAssertEqual(draft.folders[0].excludeText, "*.tmp\nnode_modules/")
        XCTAssertEqual(draft.folders[2].defaultPrefix, "Défaut/")
    }

    func testUnchangedDraftKeepsEverything() throws {
        let original = try JSONDecoder().decode(JSONValue.self, from: Data(full.utf8))
        let encoded = try roundTrip(ConfigDraft(data: Data(full.utf8)))
        // Seule différence attendue : launchAtLogin, absent à l'origine, est écrit explicitement.
        var expected = try XCTUnwrap(original.object)
        expected["launchAtLogin"] = .bool(false)
        XCTAssertEqual(encoded, expected)
    }

    func testEditsAreWrittenAndEmptyFieldsRemoved() throws {
        var draft = try ConfigDraft(data: Data(full.utf8))
        draft.awsProfile = "  "
        draft.accessKeyId = " AKIAEXAMPLE "
        draft.region = ""
        draft.intervalMinutes = 0
        draft.dailyTimes = "08:00;  20:15\n"
        draft.folders[0].excludeText = "\n  *.log \n\n"
        draft.folders[1].s3Prefix = nil
        let dict = try roundTrip(draft)
        XCTAssertNil(dict["awsProfile"])
        XCTAssertNil(dict["region"])
        XCTAssertEqual(dict["accessKeyId"], .string("AKIAEXAMPLE"))
        XCTAssertEqual(dict["sessionToken"], .string("jeton"))
        let schedule = try XCTUnwrap(dict["schedule"]?.object)
        XCTAssertNil(schedule["intervalMinutes"])
        XCTAssertEqual(schedule["dailyTimes"], .array([.string("08:00"), .string("20:15")]))
        XCTAssertEqual(schedule["jitter"], .number(5))
        guard case .array(let folders)? = dict["folders"] else { return XCTFail() }
        XCTAssertEqual(folders[0].object?["exclude"], .array([.string("*.log")]))
        XCTAssertEqual(folders[0].object?["note"], .string("x"))
        XCTAssertNil(folders[1].object?["s3Prefix"])

        let config = try draft.validate()
        XCTAssertNil(config.awsProfile)
        XCTAssertEqual(config.accessKeyId, "AKIAEXAMPLE")
    }

    func testIncompleteFileStillOpensButDoesNotValidate() throws {
        let draft = try ConfigDraft(data: Data(ConfigStore.template.utf8))
        XCTAssertEqual(draft.bucket, "mon-bucket")
        XCTAssertThrowsError(try draft.validate())

        let empty = try ConfigDraft(data: Data("{}".utf8))
        XCTAssertTrue(empty.folders.isEmpty)
        XCTAssertThrowsError(try empty.validate())
    }

    func testInvalidJSONIsRejected() {
        XCTAssertThrowsError(try ConfigDraft(data: Data("{ \"bucket\": ".utf8)))
        XCTAssertThrowsError(try ConfigDraft(data: Data("[]".utf8)))
    }

    func testInvalidTimeFailsValidation() throws {
        var draft = try ConfigDraft(data: Data(full.utf8))
        draft.dailyTimes = "25:00"
        XCTAssertThrowsError(try draft.validate())
    }

    func testFoldersJSONRoundTrip() throws {
        var draft = try ConfigDraft(data: Data(full.utf8))
        let json = draft.foldersJSON
        let before = draft.folders
        try draft.setFolders(json: json)
        XCTAssertEqual(draft.folders, before)

        try draft.setFolders(json: #"[{"localPath": "~/Nouveau", "exclude": ["a", "b"]}]"#)
        XCTAssertEqual(draft.folders.count, 1)
        XCTAssertEqual(draft.folders[0].excludePatterns, ["a", "b"])

        XCTAssertThrowsError(try draft.setFolders(json: #"{"localPath": "~/x"}"#))
        XCTAssertThrowsError(try draft.setFolders(json: #"[{"s3Prefix": "x"}]"#))
        XCTAssertThrowsError(try draft.setFolders(json: "[ oups"))
        XCTAssertEqual(draft.folders.count, 1)
    }

    func testPrettyOutputOrderAndEscaping() {
        let value = JSONValue.object([
            "folders": .array([.object(["exclude": .array([.string("a\"b")]), "localPath": .string("~/x\\y")])]),
            "bucket": .string("b"),
            "zzz": .number(1.5),
            "awsProfile": .string("p"),
        ])
        XCTAssertEqual(value.pretty(), """
        {
          "awsProfile": "p",
          "bucket": "b",
          "folders": [
            {
              "localPath": "~/x\\\\y",
              "exclude": ["a\\"b"]
            }
          ],
          "zzz": 1.5
        }
        """)
    }
}
