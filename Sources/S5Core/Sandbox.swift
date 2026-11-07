import Foundation
import Security

/// Détection de l'App Sandbox (entitlement `com.apple.security.app-sandbox` du processus).
public enum Sandbox {
    public static let isActive: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? Bool) ?? false
    }()
}

/// Dossier personnel réel de l'utilisateur. Sous sandbox, `~` et `homeDirectoryForCurrentUser`
/// désignent le conteneur de l'app (~/Library/Containers/…), pas /Users/<nom>.
public enum RealHome {
    public static let path: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    public static var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Remplace un « ~ » initial par le dossier personnel réel.
    public static func expand(_ path: String, home: String = RealHome.path) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}

/// Emplacement de ~/.aws (dans le vrai dossier personnel).
public enum AWSDirectory {
    public static var url: URL { RealHome.url.appendingPathComponent(".aws", isDirectory: true) }
    public static var path: String { url.path }
}

/// Dossiers autorisés par l'utilisateur (sélection dans un panneau d'ouverture), conservés sous forme
/// de signets à portée de sécurité. Sous sandbox, c'est la seule façon de lire ~/.aws et les dossiers
/// à synchroniser d'un lancement à l'autre. L'accès est ouvert au démarrage et gardé jusqu'à la fin de l'app.
public final class AccessGrants: @unchecked Sendable {
    public static let shared = AccessGrants(storeURL: ConfigStore.directory.appendingPathComponent("bookmarks.json"))

    private let storeURL: URL
    private let lock = NSLock()
    /// Chemin → URL dont l'accès est ouvert.
    private var active: [String: URL] = [:]

    init(storeURL: URL) {
        self.storeURL = storeURL
    }

    /// Chemins actuellement autorisés.
    public var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return active.keys.sorted()
    }

    /// Résout tous les signets enregistrés et ouvre leur accès. Renvoie les erreurs (déjà sans secret).
    @discardableResult
    public func activateAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var failures: [String] = []
        var refreshed: [String: Data] = [:]
        for (path, data) in load() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                failures.append("\(path): unreadable bookmark, grant access again")
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                failures.append("\(path): access denied, grant access again")
                continue
            }
            let key = Self.normalize(url.path)
            active[key]?.stopAccessingSecurityScopedResource()
            active[key] = url
            refreshed[key] = stale ? ((try? Self.bookmark(url)) ?? data) : data
        }
        save(refreshed)
        return failures
    }

    /// Enregistre l'autorisation donnée par l'utilisateur pour `url` et ouvre l'accès.
    public func grant(_ url: URL) throws {
        let data = try Self.bookmark(url)
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(url.path)
        var stored = load()
        stored[key] = data
        save(stored)
        if active[key] == nil, url.startAccessingSecurityScopedResource() {
            active[key] = url
        }
    }

    /// Indique si `path` est un dossier autorisé ou se trouve dans l'un d'eux.
    public func covers(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.covers(path, roots: active.keys)
    }

    /// Dossiers que la configuration utilise et qui ne sont pas encore autorisés :
    /// ~/.aws (si un profil est configuré) puis les dossiers à synchroniser.
    public func missing(for config: AppConfig) -> [String] {
        var needed = config.folders.map(\.expandedPath)
        if config.awsProfile != nil { needed.insert(AWSDirectory.path, at: 0) }
        var seen = Set<String>()
        return needed.filter { !covers($0) && seen.insert(Self.normalize($0)).inserted }
    }

    static func covers<S: Sequence>(_ path: String, roots: S) -> Bool where S.Element == String {
        let target = normalize(path)
        return roots.contains { root in
            let root = normalize(root)
            return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Chemin absolu, sans « / » final ni « .. », en NFC (le disque renvoie du NFD, config.json du NFC).
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func load() -> [String: Data] {
        guard let data = try? Data(contentsOf: storeURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private func save(_ bookmarks: [String: Data]) {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(bookmarks).write(to: storeURL, options: .atomic)
        } catch {
            Log.info("Access grants not saved: \(error.localizedDescription)")
        }
    }
}
