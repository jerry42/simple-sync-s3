import Foundation
import CryptoKit

/// Signature AWS Signature Version 4, sans état ni accès réseau (testable avec les exemples officiels AWS).
enum SigV4 {
    struct Signed {
        /// Chaîne de requête canonique, déjà encodée, à réutiliser telle quelle dans l'URL.
        let canonicalQuery: String
        /// En-têtes à envoyer (noms en minuscules), y compris x-amz-date, x-amz-content-sha256 et Authorization.
        let headers: [String: String]
        let canonicalRequest: String
        let stringToSign: String
        let signature: String
    }

    static let emptyPayloadHash = sha256Hex(Data())
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// - Parameters:
    ///   - path: chemin canonique, déjà encodé (voir `uriEncode`).
    ///   - headers: en-têtes à signer, dont `host` (les noms sont passés en minuscules).
    static func sign(method: String, path: String, query: [(String, String)], headers: [String: String],
                     payloadHash: String, region: String, service: String,
                     credentials: AWSCredentials, date: Date) -> Signed {
        let amzDate = amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        let encodedQuery: [(name: String, value: String)] = query.map { (uriEncode($0.0), uriEncode($0.1)) }
        let sortedQuery = encodedQuery.sorted { a, b in
            a.name == b.name ? a.value < b.value : a.name < b.name
        }
        let canonicalQuery = sortedQuery.map { "\($0.name)=\($0.value)" }.joined(separator: "&")

        var allHeaders: [String: String] = [:]
        for (k, v) in headers { allHeaders[k.lowercased()] = v }
        allHeaders["x-amz-content-sha256"] = payloadHash
        allHeaders["x-amz-date"] = amzDate
        if let token = credentials.sessionToken { allHeaders["x-amz-security-token"] = token }

        let sortedKeys = allHeaders.keys.sorted()
        let canonicalHeaders = sortedKeys
            .map { "\($0):\(allHeaders[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = sortedKeys.joined(separator: ";")

        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        let kDate = hmac(Data("AWS4\(credentials.secretAccessKey)".utf8), dateStamp)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        let kSigning = hmac(kService, "aws4_request")
        let signature = hex(hmac(kSigning, stringToSign))

        allHeaders["authorization"] = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return Signed(canonicalQuery: canonicalQuery, headers: allHeaders, canonicalRequest: canonicalRequest,
                      stringToSign: stringToSign, signature: signature)
    }

    // MARK: - Helpers

    static func uriEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
