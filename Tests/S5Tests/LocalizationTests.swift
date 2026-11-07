import XCTest
@testable import S5Core

/// Checks the translation files copied into the app by scripts/build-app.sh.
final class LocalizationTests: XCTestCase {
    private let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    private func strings(_ language: String, _ table: String) throws -> [String: String] {
        let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/\(table).strings"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: String])
    }

    private func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(lld|@|%)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }

    func testFrenchTranslationsKeepTheFormatSpecifiers() throws {
        let french = try strings("fr", "Localizable")
        XCTAssertGreaterThan(french.count, 100)
        for (key, value) in french {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(specifiers(key), specifiers(value), "\(key) → \(value)")
        }
    }

    func testEnglishLocalizationExists() {
        let path = resources.appendingPathComponent("en.lproj/Localizable.strings").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
    }

    func testFrenchInfoPlistTexts() throws {
        let french = try strings("fr", "InfoPlist")
        XCTAssertEqual(Set(french.keys), [
            "NSDocumentsFolderUsageDescription", "NSDesktopFolderUsageDescription", "NSDownloadsFolderUsageDescription",
            "NSRemovableVolumesUsageDescription", "NSNetworkVolumesUsageDescription",
        ])
    }

    func testHelpPageInEachLanguage() {
        for language in ["en", "fr"] {
            let path = resources.appendingPathComponent("\(language).lproj/Help.html").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        }
    }

    func testWithoutTranslationTheEnglishKeyIsUsed() {
        XCTAssertEqual(L10n.tr("%@: %@%% (%@ / %@)", "F", "50", "1", "2"), "F: 50% (1 / 2)")
        XCTAssertEqual(L10n.tr("%lld uploaded", 3), "3 uploaded")
    }
}
