import XCTest
@testable import S5Core

final class ClockSkewTests: XCTestCase {
    private let url = URL(string: "https://my-bucket.s3.eu-west-3.amazonaws.com/")!

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func skewBody(serverTime: String?) -> Data {
        let server = serverTime.map { "<ServerTime>\($0)</ServerTime>" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>RequestTimeTooSkewed</Code><Message>The difference between the request time and the current time is too large.</Message><RequestTime>20261109T214939Z</RequestTime>\(server)<MaxAllowedSkewMilliseconds>900000</MaxAllowedSkewMilliseconds></Error>
        """.utf8)
    }

    // Mac en retard de 30 min sur S3.
    private let now = ISO8601DateFormatter().date(from: "2026-11-09T21:49:39Z")!

    func testOffsetFromServerTimeInBody() {
        let offset = S3Client.skewCorrection(response(403), skewBody(serverTime: "2026-11-09T22:19:39Z"), now: now)
        XCTAssertEqual(offset, 1800)
    }

    func testOffsetFromDateHeaderWhenBodyHasNoServerTime() {
        let offset = S3Client.skewCorrection(response(403, headers: ["Date": "Mon, 09 Nov 2026 21:19:39 GMT"]),
                                             skewBody(serverTime: nil), now: now)
        XCTAssertEqual(offset, -1800)
    }

    func testIgnoresOtherErrors() {
        let body = Data("<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8)
        XCTAssertNil(S3Client.skewCorrection(response(403, headers: ["Date": "Mon, 09 Nov 2026 21:19:39 GMT"]), body, now: now))
        XCTAssertNil(S3Client.skewCorrection(response(200), skewBody(serverTime: "2026-11-09T22:19:39Z"), now: now))
    }
}
