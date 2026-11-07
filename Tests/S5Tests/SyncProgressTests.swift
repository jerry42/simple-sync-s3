import XCTest
@testable import S5Core

final class SyncProgressTests: XCTestCase {
    private let fs = SyncProgress.figureSpace

    func testFormat() {
        XCTAssertEqual(SyncProgress.files(folder: "Dropbox", done: 0, total: 1234), "Dropbox : \(fs)\(fs)0 % (\(fs)\(fs)\(fs)0 / 1234)")
        XCTAssertEqual(SyncProgress.files(folder: "Dropbox", done: 456, total: 1234), "Dropbox : \(fs)36 % (\(fs)456 / 1234)")
        XCTAssertEqual(SyncProgress.files(folder: "Dropbox", done: 1234, total: 1234), "Dropbox : 100 % (1234 / 1234)")
    }

    func testWidthIsStableWithinAFolder() {
        let lengths = Set((0...250).map { SyncProgress.files(folder: "F", done: $0, total: 250).count })
        XCTAssertEqual(lengths.count, 1)
    }

    func testNeverReaches100BeforeTheEnd() {
        XCTAssertTrue(SyncProgress.files(folder: "F", done: 999, total: 1000).contains("99 %"))
    }

    func testEmptyFolder() {
        XCTAssertEqual(SyncProgress.files(folder: "F", done: 0, total: 0), "F : 100 % (0 / 0)")
    }
}
