import XCTest
@testable import S5Core

final class SigV4Tests: XCTestCase {
    // Identifiants des exemples de la documentation AWS « Signature Calculations (AWS Signature Version 4) » pour S3.
    private let docCredentials = AWSCredentials(accessKeyId: "AKIAIOSFODNN7EXAMPLE",
                                                secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                                                sessionToken: nil, expiration: nil)
    private let docDate = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z

    // Valeurs de référence calculées par botocore (embarqué dans l'AWS CLI v2) avec ces mêmes paramètres.
    private let botoCredentials = AWSCredentials(accessKeyId: "AKIDEXAMPLE",
                                                 secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                                 sessionToken: nil, expiration: nil)
    private let botoDate = Date(timeIntervalSince1970: 1_793_926_923) // 2026-11-06T01:02:03Z

    func testAWSDocumentationGetObjectExample() {
        let signed = SigV4.sign(method: "GET", path: "/test.txt", query: [],
                                headers: ["Host": "examplebucket.s3.amazonaws.com", "Range": "bytes=0-9"],
                                payloadHash: SigV4.emptyPayloadHash, region: "us-east-1", service: "s3",
                                credentials: docCredentials, date: docDate)
        XCTAssertEqual(signed.signature, "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(signed.headers["authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
                       + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
                       + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(signed.headers["x-amz-date"], "20130524T000000Z")
    }

    func testAWSDocumentationListObjectsExample() {
        let signed = SigV4.sign(method: "GET", path: "/", query: [("prefix", "J"), ("max-keys", "2")],
                                headers: ["host": "examplebucket.s3.amazonaws.com"],
                                payloadHash: SigV4.emptyPayloadHash, region: "us-east-1", service: "s3",
                                credentials: docCredentials, date: docDate)
        XCTAssertEqual(signed.canonicalQuery, "max-keys=2&prefix=J")
        XCTAssertEqual(signed.signature, "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    func testPutWithUnicodeKeyAndSessionTokenMatchesBotocore() {
        let client = S3Client(bucket: "my-bucket", region: "eu-west-3",
                              credentials: AWSCredentialProvider(profile: "unused"))
        let path = client.path(forKey: "dossier/été 2024/facture+1.pdf")
        XCTAssertEqual(path, "/dossier/%C3%A9t%C3%A9%202024/facture%2B1.pdf")

        let credentials = AWSCredentials(accessKeyId: botoCredentials.accessKeyId,
                                         secretAccessKey: botoCredentials.secretAccessKey,
                                         sessionToken: "FQoGZXIvYXdzEXAMPLETOKEN//+=", expiration: nil)
        let signed = SigV4.sign(method: "PUT", path: path, query: [],
                                headers: ["host": client.host, "content-type": "application/pdf"],
                                payloadHash: SigV4.emptyPayloadHash, region: "eu-west-3", service: "s3",
                                credentials: credentials, date: botoDate)
        XCTAssertEqual(signed.headers["x-amz-security-token"], "FQoGZXIvYXdzEXAMPLETOKEN//+=")
        XCTAssertEqual(signed.headers["authorization"],
                       "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261106/eu-west-3/s3/aws4_request, "
                       + "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, "
                       + "Signature=89f63cd6a00675ea552b62ec04c7a144a884a256bf76e2580fb1c2b6c207c5cf")
    }

    func testListWithContinuationTokenMatchesBotocore() {
        let signed = SigV4.sign(method: "GET", path: "/",
                                query: [("list-type", "2"), ("prefix", "factures/"),
                                        ("continuation-token", "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")],
                                headers: ["host": "my-bucket.s3.eu-west-3.amazonaws.com"],
                                payloadHash: SigV4.emptyPayloadHash, region: "eu-west-3", service: "s3",
                                credentials: botoCredentials, date: botoDate)
        XCTAssertEqual(signed.canonicalQuery,
                       "continuation-token=1ueGcxLPRx1Tr%2FXYExHnhbYLgveDs2J%2Fwm36Hy4vbOwM%3D&list-type=2&prefix=factures%2F")
        XCTAssertEqual(signed.signature, "26b96b9d1ae0c48422160693fb427f5442923e03c2c5d7ff33f1e182233df27a")
    }

    func testEmptyQueryValueIsKept() {
        let signed = SigV4.sign(method: "GET", path: "/", query: [("prefix", ""), ("list-type", "2")],
                                headers: ["host": "h"], payloadHash: SigV4.emptyPayloadHash,
                                region: "eu-west-3", service: "s3", credentials: botoCredentials, date: botoDate)
        XCTAssertEqual(signed.canonicalQuery, "list-type=2&prefix=")
    }

    func testURIEncode() {
        XCTAssertEqual(SigV4.uriEncode("a b+c/d~e_f-g.h"), "a%20b%2Bc%2Fd~e_f-g.h")
        XCTAssertEqual(SigV4.uriEncode("é"), "%C3%A9")
        XCTAssertEqual(SigV4.uriEncode(""), "")
    }

    func testDottedBucketUsesPathStyle() {
        let client = S3Client(bucket: "my.bucket", region: "eu-west-3",
                              credentials: AWSCredentialProvider(profile: "unused"))
        XCTAssertEqual(client.host, "s3.eu-west-3.amazonaws.com")
        XCTAssertEqual(client.path(forKey: "a/b.txt"), "/my.bucket/a/b.txt")
    }

    func testEmptyPayloadHash() {
        XCTAssertEqual(SigV4.emptyPayloadHash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
