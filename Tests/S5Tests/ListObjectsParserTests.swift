import XCTest
@testable import S5Core

final class ListObjectsParserTests: XCTestCase {
    func testParsesPageWithContinuationToken() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>my-bucket</Name>
          <Prefix>factures/</Prefix>
          <KeyCount>3</KeyCount>
          <MaxKeys>1000</MaxKeys>
          <IsTruncated>true</IsTruncated>
          <ContinuationToken>previous</ContinuationToken>
          <NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken>
          <Contents>
            <Key>factures/2024/janvier.pdf</Key>
            <LastModified>2024-02-01T10:00:00.000Z</LastModified>
            <ETag>&quot;9b2cf535f27731c974343645a3985328&quot;</ETag>
            <Size>12345</Size>
            <Owner><ID>abc</ID><DisplayName>me</DisplayName></Owner>
            <StorageClass>STANDARD</StorageClass>
          </Contents>
          <Contents>
            <Key>factures/R&amp;D été.txt</Key>
            <ETag>"d41d8cd98f00b204e9800998ecf8427e-3"</ETag>
            <Size>0</Size>
          </Contents>
          <Contents>
            <Key>factures/gros.bin</Key>
            <ETag>&quot;0123&quot;</ETag>
            <Size>6000000000</Size>
          </Contents>
          <CommonPrefixes><Prefix>factures/sous/</Prefix></CommonPrefixes>
        </ListBucketResult>
        """
        let page = ListObjectsParser.parse(Data(xml.utf8))
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextToken, "1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=")
        XCTAssertEqual(page.objects.map(\.key), ["factures/2024/janvier.pdf", "factures/R&D été.txt", "factures/gros.bin"])
        XCTAssertEqual(page.objects.map(\.size), [12345, 0, 6_000_000_000])
        XCTAssertEqual(page.objects.map(\.etag),
                       ["9b2cf535f27731c974343645a3985328", "d41d8cd98f00b204e9800998ecf8427e-3", "0123"])
    }

    func testLastPage() {
        let xml = """
        <ListBucketResult><IsTruncated>false</IsTruncated>
        <Contents><Key>a</Key><ETag>"x"</ETag><Size>1</Size></Contents></ListBucketResult>
        """
        let page = ListObjectsParser.parse(Data(xml.utf8))
        XCTAssertFalse(page.isTruncated)
        XCTAssertNil(page.nextToken)
        XCTAssertEqual(page.objects.count, 1)
    }

    func testEmptyResult() {
        let page = ListObjectsParser.parse(Data("<ListBucketResult><KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        XCTAssertTrue(page.objects.isEmpty)
        XCTAssertFalse(page.isTruncated)
    }

    func testKeyWithLeadingAndTrailingSpacesIsKept() {
        let xml = "<ListBucketResult><Contents><Key> a b </Key><Size>1</Size></Contents></ListBucketResult>"
        XCTAssertEqual(ListObjectsParser.parse(Data(xml.utf8)).objects.first?.key, " a b ")
    }

    func testInvalidXMLReturnsEmptyPage() {
        let page = ListObjectsParser.parse(Data("not xml".utf8))
        XCTAssertTrue(page.objects.isEmpty)
        XCTAssertFalse(page.isTruncated)
    }
}
