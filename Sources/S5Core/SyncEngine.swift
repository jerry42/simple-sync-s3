import Foundation
import CryptoKit
import UniformTypeIdentifiers

public struct SyncReport: Sendable {
    public var uploaded = 0
    public var deleted = 0
    public var unchanged = 0
    public var errors: [String] = []
    public var cancelled = false

    public init() {}

    mutating func merge(_ other: SyncReport) {
        uploaded += other.uploaded
        deleted += other.deleted
        unchanged += other.unchanged
        errors += other.errors
        cancelled = cancelled || other.cancelled
    }

    public var summary: String {
        var parts = [L10n.tr("%lld uploaded", uploaded), L10n.tr("%lld deleted", deleted),
                     L10n.tr("%lld unchanged", unchanged)]
        if !errors.isEmpty { parts.append(L10n.tr("%lld error(s)", errors.count)) }
        if cancelled { parts.append(L10n.tr("interrupted")) }
        return parts.joined(separator: ", ")
    }
}

enum SyncError: LocalizedError {
    case missingRegion
    case folderMissing(String)
    case folderNotAuthorized(String)
    case fileTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .missingRegion:
            return L10n.tr("Unknown AWS region: add \"region\" to config.json (or to ~/.aws/config for the profile).")
        case .folderMissing(let path):
            return L10n.tr("Folder not found: %@ (skipped, nothing is deleted from S3)", path)
        case .folderNotAuthorized(let path):
            return L10n.tr("Access not granted (sandbox): %@ (“Grant Access…” menu; nothing is deleted from S3)", path)
        case .fileTooLarge(let path):
            return L10n.tr("Files over 5 GB are not supported yet: %@", path)
        }
    }
}

/// Synchronisation à sens unique : local → S3.
public final class SyncEngine {
    private static let maxSinglePutSize: Int64 = 5 * 1024 * 1024 * 1024

    private let config: AppConfig
    private let client: S3Client
    private let state: SyncStateStore
    private let progress: (String) -> Void

    /// `stateURL` : cache taille + date des fichiers envoyés (par défaut dans Application Support).
    public init(config: AppConfig, stateURL: URL = ConfigStore.stateURL,
                progress: @escaping (String) -> Void) throws {
        self.config = config
        self.state = SyncStateStore(url: stateURL)
        self.progress = progress
        let provider = AWSCredentialProvider(config: config)
        guard let region = config.region ?? provider.region() else { throw SyncError.missingRegion }
        self.client = S3Client(bucket: config.bucket, region: region, credentials: provider)
    }

    public func run() async -> SyncReport {
        var report = SyncReport()
        for folder in config.folders {
            if Task.isCancelled { report.cancelled = true; break }
            do {
                report.merge(try await sync(folder: folder))
            } catch {
                report.errors.append(L10n.tr("%@: %@", folder.localPath, error.localizedDescription))
            }
            state.save()
        }
        state.save()
        return report
    }

    // MARK: - Un dossier

    private struct LocalFile {
        let url: URL
        let size: Int64
        let mtime: TimeInterval
    }

    private func sync(folder: FolderConfig) async throws -> SyncReport {
        var report = SyncReport()
        let rootPath = folder.expandedPath
        if Sandbox.isActive && !AccessGrants.shared.covers(rootPath) {
            throw SyncError.folderNotAuthorized(rootPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.folderMissing(rootPath)
        }

        let excludes = ExcludeRules(folder.exclude ?? [])
        let prefix = folder.normalizedPrefix
        // Messages de progression courts et de forme fixe (dossier + compteur, jamais le nom d'un fichier) :
        // ils s'affichent dans le menu, dont la largeur suit le texte.
        let name = URL(fileURLWithPath: rootPath).lastPathComponent
        progress(L10n.tr("%@: scanning…", name))
        let local = scanLocal(rootPath: rootPath, excludes: excludes)
        let remote = try await client.listObjects(prefix: prefix)
        Log.info("\(folder.localPath) → s3://\(config.bucket)/\(prefix): \(local.count) local file(s), \(remote.count) remote object(s)")

        // Envois
        for (index, (rel, file)) in local.sorted(by: { $0.key < $1.key }).enumerated() {
            if Task.isCancelled { report.cancelled = true; return report }
            progress(SyncProgress.files(folder: name, done: index, total: local.count))
            let key = prefix + rel
            do {
                if try needsUpload(key: key, file: file, remote: remote[key]) {
                    guard file.size <= Self.maxSinglePutSize else { throw SyncError.fileTooLarge(file.url.path) }
                    try await client.putObject(key: key, fileURL: file.url, contentType: Self.contentType(for: file.url))
                    state.record(bucket: config.bucket, key: key, size: file.size, mtime: file.mtime)
                    Log.info("↑ \(key)")
                    report.uploaded += 1
                } else {
                    report.unchanged += 1
                }
            } catch {
                if Task.isCancelled { report.cancelled = true; return report }
                Log.info("Error \(key): \(error.localizedDescription)")
                report.errors.append(L10n.tr("%@: %@", rel, error.localizedDescription))
            }
        }

        progress(SyncProgress.files(folder: name, done: local.count, total: local.count))

        // Suppressions (uniquement si activé)
        guard config.deleteRemote else { return report }
        if prefix.isEmpty {
            Log.info("Deletion disabled for \(folder.localPath): empty S3 prefix (would cover the whole bucket).")
            return report
        }
        if local.isEmpty && !remote.isEmpty {
            Log.info("Deletion skipped for \(folder.localPath): local folder is empty, for safety.")
            return report
        }
        let localKeys = Set(local.keys.map { prefix + $0 })
        for key in remote.keys.sorted() where !localKeys.contains(key) {
            if Task.isCancelled { report.cancelled = true; return report }
            let rel = String(key.dropFirst(prefix.count))
            if rel.isEmpty || rel.hasSuffix("/") { continue }
            if excludes.isExcluded(rel, isDirectory: false) { continue }
            do {
                progress(L10n.tr("%@: deleting…", name))
                try await client.deleteObject(key: key)
                state.remove(bucket: config.bucket, key: key)
                Log.info("✕ \(key)")
                report.deleted += 1
            } catch {
                report.errors.append(L10n.tr("delete %@: %@", rel, error.localizedDescription))
            }
        }
        return report
    }

    private func needsUpload(key: String, file: LocalFile, remote: S3Object?) throws -> Bool {
        guard let remote else { return true }
        if remote.size != file.size { return true }
        if let saved = state.entry(bucket: config.bucket, key: key),
           saved.size == file.size, saved.mtime == file.mtime {
            return false
        }
        // État inconnu ou date changée : on compare le MD5 à l'ETag (valable pour un envoi simple).
        guard !remote.etag.contains("-") else { return true }
        let localMD5 = try Self.md5Hex(file.url)
        if localMD5 == remote.etag.lowercased() {
            state.record(bucket: config.bucket, key: key, size: file.size, mtime: file.mtime)
            return false
        }
        return true
    }

    // MARK: - Fichiers locaux

    private func scanLocal(rootPath: String, excludes: ExcludeRules) -> [String: LocalFile] {
        var result: [String: LocalFile] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return result }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        while let rel = enumerator.nextObject() as? String {
            let attrs = enumerator.fileAttributes ?? [:]
            let type = attrs[.type] as? FileAttributeType
            // Les dossiers exclus ne sont pas parcourus : inutile de retester les parents.
            if excludes.excludesItem(rel, isDirectory: type == .typeDirectory) {
                if type == .typeDirectory { enumerator.skipDescendants() }
                continue
            }
            guard type == .typeRegular else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            // macOS stocke les noms en NFD : on normalise en NFC pour des clés S3 stables.
            let key = rel.precomposedStringWithCanonicalMapping
            result[key] = LocalFile(url: rootURL.appendingPathComponent(rel), size: size, mtime: mtime)
        }
        return result
    }

    private static func md5Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while true {
            let chunk: Data = try autoreleasepool { try handle.read(upToCount: 4 * 1024 * 1024) ?? Data() }
            if chunk.isEmpty { break }
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func contentType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }
}
