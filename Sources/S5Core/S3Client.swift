import Foundation

struct S3Object {
    let key: String
    let size: Int64
    /// ETag sans guillemets (MD5 pour un envoi simple, "xxx-N" pour un multipart).
    let etag: String
}

enum S3Error: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let message = S3Error.extract(tag: "Message", from: body) ?? body
            let s3Code = S3Error.extract(tag: "Code", from: body).map { "\($0) : " } ?? ""
            return "S3 HTTP \(code) – \(s3Code)\(message.prefix(300))"
        case .invalidResponse:
            return "Réponse S3 invalide"
        }
    }

    private static func extract(tag: String, from body: String) -> String? {
        guard let start = body.range(of: "<\(tag)>"),
              let end = body.range(of: "</\(tag)>", range: start.upperBound..<body.endIndex) else { return nil }
        return String(body[start.upperBound..<end.lowerBound])
    }
}

/// Client S3 minimal (ListObjectsV2, PutObject, DeleteObject) signé en AWS Signature V4.
/// Aucune dépendance externe : Foundation + CryptoKit.
final class S3Client {
    let bucket: String
    let region: String
    private let credentials: AWSCredentialProvider
    private let session: URLSession

    init(bucket: String, region: String, credentials: AWSCredentialProvider) {
        self.bucket = bucket
        self.region = region
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 6 * 3600
        self.session = URLSession(configuration: config)
    }

    // Un bucket contenant des points casse le certificat TLS en virtual-hosted : on passe alors en path-style.
    private var pathStyle: Bool { bucket.contains(".") }

    var host: String {
        pathStyle ? "s3.\(region).amazonaws.com" : "\(bucket).s3.\(region).amazonaws.com"
    }

    private var rootPath: String {
        pathStyle ? "/\(SigV4.uriEncode(bucket))" : "/"
    }

    func path(forKey key: String) -> String {
        let encoded = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4.uriEncode(String($0)) }
            .joined(separator: "/")
        return pathStyle ? "/\(SigV4.uriEncode(bucket))/\(encoded)" : "/\(encoded)"
    }

    // MARK: - API

    func listObjects(prefix: String) async throws -> [String: S3Object] {
        var result: [String: S3Object] = [:]
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let token { query.append(("continuation-token", token)) }
            let request = try signedRequest(method: "GET", path: rootPath, query: query, payloadHash: SigV4.emptyPayloadHash)
            let (data, response) = try await session.data(for: request)
            try Self.check(response, data)
            let page = ListObjectsParser.parse(data)
            for object in page.objects { result[object.key] = object }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
        return result
    }

    func putObject(key: String, fileURL: URL, contentType: String?) async throws {
        var headers: [String: String] = [:]
        if let contentType { headers["content-type"] = contentType }
        let request = try signedRequest(method: "PUT", path: path(forKey: key), query: [],
                                        payloadHash: "UNSIGNED-PAYLOAD", extraHeaders: headers)
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.check(response, data)
    }

    func deleteObject(key: String) async throws {
        let request = try signedRequest(method: "DELETE", path: path(forKey: key), query: [],
                                        payloadHash: SigV4.emptyPayloadHash)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
    }

    // MARK: - Signature V4

    private func signedRequest(method: String, path: String, query: [(String, String)],
                               payloadHash: String, extraHeaders: [String: String] = [:]) throws -> URLRequest {
        var headers = extraHeaders
        headers["host"] = host
        let signed = SigV4.sign(method: method, path: path, query: query, headers: headers,
                                payloadHash: payloadHash, region: region, service: "s3",
                                credentials: try credentials.credentials(), date: Date())

        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.percentEncodedPath = path
        if !signed.canonicalQuery.isEmpty { components.percentEncodedQuery = signed.canonicalQuery }
        guard let url = components.url else { throw S3Error.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in signed.headers where k != "host" {
            request.setValue(v, forHTTPHeaderField: k)
        }
        return request
    }

    // MARK: - Helpers

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}

/// Parse la réponse XML de ListObjectsV2.
final class ListObjectsParser: NSObject, XMLParserDelegate {
    struct Page {
        var objects: [S3Object] = []
        var isTruncated = false
        var nextToken: String?
    }

    private var page = Page()
    private var text = ""
    private var inContents = false
    private var key = ""
    private var size: Int64 = 0
    private var etag = ""

    static func parse(_ data: Data) -> Page {
        let delegate = ListObjectsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.page
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "Contents" {
            inContents = true
            key = ""; size = 0; etag = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "Key" where inContents: key = text
        case "Size" where inContents: size = Int64(text) ?? 0
        case "ETag" where inContents: etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "Contents":
            page.objects.append(S3Object(key: key, size: size, etag: etag))
            inContents = false
        case "IsTruncated": page.isTruncated = (text == "true")
        case "NextContinuationToken": page.nextToken = text
        default: break
        }
        text = ""
    }
}
