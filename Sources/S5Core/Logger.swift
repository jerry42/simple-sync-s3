import Foundation

public enum Log {
    public static var fileURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/SimpleSyncS3/sync.log")
    }

    private static let queue = DispatchQueue(label: "SimpleSyncS3.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Les tests unitaires n'écrivent pas dans le vrai journal.
    private static let writesFile = NSClassFromString("XCTestCase") == nil

    public static func info(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        print(line, terminator: "")
        guard writesFile else { return }
        queue.async {
            let fm = FileManager.default
            let url = fileURL
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    /// Attend l'écriture des lignes en attente (avant de quitter un outil en ligne de commande).
    public static func flush() {
        queue.sync {}
    }
}
