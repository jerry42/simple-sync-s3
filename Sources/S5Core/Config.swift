import Foundation

/// Configuration lue depuis ~/Library/Application Support/SimpleSyncS3/config.json
public struct AppConfig: Codable, Sendable {
    /// Profil AWS. Absent : "default", sauf si `accessKeyId` est renseigné (la clé d'accès est alors utilisée seule).
    public var awsProfile: String?
    /// Clé d'accès utilisée si le profil est absent ou inaccessible. La clé secrète est dans le trousseau.
    public var accessKeyId: String?
    public var sessionToken: String?
    /// Clé secrète en clair : dernier recours, déconseillé.
    public var secretAccessKey: String?
    public var region: String?
    public var bucket: String
    public var folders: [FolderConfig]
    public var schedule: ScheduleConfig
    public var deleteRemote: Bool
    public var launchAtLogin: Bool

    enum CodingKeys: String, CodingKey {
        case awsProfile, accessKeyId, sessionToken, secretAccessKey, region, bucket, folders, schedule, deleteRemote, launchAtLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func optional(_ key: CodingKeys) throws -> String? {
            let value = try c.decodeIfPresent(String.self, forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        accessKeyId = try optional(.accessKeyId)
        sessionToken = try optional(.sessionToken)
        secretAccessKey = try optional(.secretAccessKey)
        awsProfile = try optional(.awsProfile) ?? (accessKeyId == nil ? "default" : nil)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        bucket = try c.decode(String.self, forKey: .bucket)
        folders = try c.decodeIfPresent([FolderConfig].self, forKey: .folders) ?? []
        schedule = try c.decodeIfPresent(ScheduleConfig.self, forKey: .schedule) ?? ScheduleConfig()
        deleteRemote = try c.decodeIfPresent(Bool.self, forKey: .deleteRemote) ?? false
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }

    var staticKey: StaticKeyConfig? {
        accessKeyId.map { StaticKeyConfig(accessKeyId: $0, sessionToken: sessionToken, plaintextSecret: secretAccessKey) }
    }
}

public struct FolderConfig: Codable, Sendable {
    /// Chemin local, "~" accepté.
    public var localPath: String
    /// Préfixe dans le bucket. Par défaut : le nom du dossier local.
    public var s3Prefix: String?
    /// Motifs ignorés, sémantique `.gitignore` relative au dossier (voir `ExcludeRules`).
    public var exclude: [String]?

    /// Chemin absolu ; « ~ » désigne le vrai dossier personnel, même sous sandbox.
    public var expandedPath: String {
        RealHome.expand(localPath)
    }

    /// Préfixe normalisé : "" ou "quelque/chose/".
    var normalizedPrefix: String {
        let raw = s3Prefix ?? URL(fileURLWithPath: expandedPath).lastPathComponent
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.isEmpty ? "" : trimmed + "/"
    }
}

public struct ScheduleConfig: Codable, Sendable {
    /// Synchro toutes les N minutes (absent ou 0 = désactivé).
    public var intervalMinutes: Int?
    /// Heures fixes quotidiennes au format "HH:mm".
    public var dailyTimes: [String]?
    /// Lancer une synchro au démarrage de l'app.
    public var syncOnLaunch: Bool?

    public init(intervalMinutes: Int? = nil, dailyTimes: [String]? = nil, syncOnLaunch: Bool? = nil) {
        self.intervalMinutes = intervalMinutes
        self.dailyTimes = dailyTimes
        self.syncOnLaunch = syncOnLaunch
    }
}

enum ConfigError: LocalizedError {
    case createdTemplate(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .createdTemplate(let path):
            return "Fichier de configuration créé, à compléter : \(path)"
        case .invalid(let message):
            return "Configuration invalide : \(message)"
        }
    }
}

public enum ConfigStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SimpleSyncS3", isDirectory: true)
    }

    /// Dossier de l'app avant son renommage (MyDropbox → Simple Sync S3).
    static var legacyDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyDropbox", isDirectory: true)
    }

    /// Reprend la configuration, le cache de synchro et les autorisations de l'ancien nom de l'app,
    /// une seule fois : seulement si le nouveau dossier n'existe pas encore. Les fichiers sont copiés
    /// (l'ancien dossier reste intact). Sous sandbox, l'ancien conteneur n'est pas lisible : rien à faire.
    @discardableResult
    public static func migrateLegacyDirectory() -> Bool {
        migrate(from: legacyDirectory, to: directory)
    }

    static func migrate(from legacy: URL, to current: URL) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: current.path),
              let items = try? fm.contentsOfDirectory(atPath: legacy.path), !items.isEmpty else { return false }
        do {
            try fm.createDirectory(at: current, withIntermediateDirectories: true)
            for name in items {
                try fm.copyItem(at: legacy.appendingPathComponent(name), to: current.appendingPathComponent(name))
            }
            Log.info("Configuration reprise de \(legacy.path) vers \(current.path)")
            return true
        } catch {
            Log.info("Reprise de \(legacy.path) impossible : \(error.localizedDescription)")
            return false
        }
    }

    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var stateURL: URL { directory.appendingPathComponent("state.json") }

    static let template = """
    {
      "awsProfile": "default",
      "region": "eu-west-3",
      "bucket": "mon-bucket",
      "deleteRemote": false,
      "launchAtLogin": false,
      "schedule": {
        "intervalMinutes": 60,
        "dailyTimes": ["02:00"],
        "syncOnLaunch": false
      },
      "folders": [
        {
          "localPath": "~/Documents/Exemple",
          "s3Prefix": "exemple",
          "exclude": ["*.tmp"]
        }
      ]
    }

    """

    public static func load() throws -> AppConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configURL.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try template.write(to: configURL, atomically: true, encoding: .utf8)
            // Le fichier peut recevoir une clé secrète : lisible par l'utilisateur seul.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            throw ConfigError.createdTemplate(configURL.path)
        }
        return try decode(Data(contentsOf: configURL))
    }

    /// Charge une configuration depuis un chemin quelconque (outil en ligne de commande), sans créer de modèle.
    public static func load(from url: URL) throws -> AppConfig {
        try decode(Data(contentsOf: url))
    }

    /// Décode et valide le contenu de config.json.
    static func decode(_ data: Data) throws -> AppConfig {
        let config: AppConfig
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch let DecodingError.keyNotFound(key, _) {
            throw ConfigError.invalid("clé manquante « \(key.stringValue) »")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ConfigError.invalid("type incorrect pour « \(ctx.codingPath.map(\.stringValue).joined(separator: ".")) »")
        } catch {
            throw ConfigError.invalid(error.localizedDescription)
        }
        if config.bucket.isEmpty || config.bucket == "mon-bucket" {
            throw ConfigError.invalid("renseigne le nom du bucket")
        }
        if config.folders.isEmpty {
            throw ConfigError.invalid("aucun dossier à synchroniser")
        }
        if config.accessKeyId == nil && (config.secretAccessKey != nil || config.sessionToken != nil) {
            throw ConfigError.invalid("« secretAccessKey » et « sessionToken » demandent « accessKeyId »")
        }
        for time in config.schedule.dailyTimes ?? [] where Scheduler.parseTime(time) == nil {
            throw ConfigError.invalid("heure « \(time) » invalide (format HH:mm)")
        }
        return config
    }
}
