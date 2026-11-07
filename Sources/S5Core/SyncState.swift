import Foundation

/// Mémorise, pour chaque objet envoyé, la taille et la date de modification du fichier local
/// au moment de l'envoi. Évite de relire / ré-envoyer les fichiers inchangés.
final class SyncStateStore {
    struct Entry: Codable {
        var size: Int64
        var mtime: TimeInterval
    }

    private var entries: [String: Entry] = [:]
    private let url: URL
    private var dirty = false

    init(url: URL = ConfigStore.stateURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func entry(bucket: String, key: String) -> Entry? {
        entries["\(bucket)/\(key)"]
    }

    func record(bucket: String, key: String, size: Int64, mtime: TimeInterval) {
        entries["\(bucket)/\(key)"] = Entry(size: size, mtime: mtime)
        dirty = true
    }

    func remove(bucket: String, key: String) {
        if entries.removeValue(forKey: "\(bucket)/\(key)") != nil { dirty = true }
    }

    func save() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            Log.info("Impossible d'enregistrer l'état : \(error.localizedDescription)")
        }
    }
}
