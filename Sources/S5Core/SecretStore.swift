import Foundation
import Security

/// Source de la clé secrète associée à une clé d'accès AWS (injectable pour les tests).
protocol SecretStore {
    func secret(for accessKeyId: String) throws -> String?
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "erreur inconnue"
        return "Trousseau : \(message) (\(status))"
    }
}

/// Clé secrète AWS dans le trousseau macOS : mot de passe générique, service « SimpleSyncS3 »,
/// compte = clé d'accès. L'élément est créé par l'app elle-même, qui peut ensuite le lire sans invite.
/// Un élément enregistré sous l'ancien nom de l'app (service « MyDropbox ») est encore lu,
/// puis recopié sous le nouveau nom.
public struct KeychainSecretStore: SecretStore {
    public static let service = "SimpleSyncS3"
    static let legacyService = "MyDropbox"

    public init() {}

    private func query(_ accessKeyId: String, service: String = Self.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accessKeyId]
    }

    public func secret(for accessKeyId: String) throws -> String? {
        if let secret = try read(accessKeyId, service: Self.service) { return secret }
        guard let legacy = try read(accessKeyId, service: Self.legacyService) else { return nil }
        // Recopie sous le nouveau nom ; en cas d'échec, l'ancien élément reste utilisable.
        if (try? save(legacy, for: accessKeyId)) != nil {
            Log.info("Clé secrète du trousseau reprise de l'ancien nom de l'app (MyDropbox)")
        }
        return legacy
    }

    private func read(_ accessKeyId: String, service: String) throws -> String? {
        var q = query(accessKeyId, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Indique si un élément existe, sans lire la clé secrète (donc sans invite d'accès).
    public func hasSecret(for accessKeyId: String) -> Bool {
        [Self.service, Self.legacyService].contains { service in
            var q = query(accessKeyId, service: service)
            q[kSecReturnAttributes as String] = true
            return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
        }
    }

    /// Enregistre ou remplace la clé secrète. L'ancien élément est supprimé puis recréé
    /// pour que son contrôle d'accès soit celui de l'app.
    public func save(_ secret: String, for accessKeyId: String) throws {
        try delete(accessKeyId, service: Self.service)
        try? delete(accessKeyId, service: Self.legacyService)
        var q = query(accessKeyId)
        q[kSecValueData as String] = Data(secret.utf8)
        q[kSecAttrLabel as String] = "Simple Sync S3 – clé secrète AWS"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Supprime la clé secrète, sous le nouveau nom comme sous l'ancien.
    public func delete(for accessKeyId: String) throws {
        try delete(accessKeyId, service: Self.service)
        try delete(accessKeyId, service: Self.legacyService)
    }

    private func delete(_ accessKeyId: String, service: String) throws {
        let status = SecItemDelete(query(accessKeyId, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
