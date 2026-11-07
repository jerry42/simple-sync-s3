import Foundation

/// Valeur JSON quelconque : permet de réécrire config.json sans perdre les clés inconnues de l'app.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
}

// MARK: - Écriture lisible

extension JSONValue {
    /// Ordre des clés connues (celui du modèle de config.json) ; les autres suivent, triées.
    static let keyOrder = ["awsProfile", "accessKeyId", "sessionToken", "secretAccessKey", "region", "bucket",
                           "deleteRemote", "launchAtLogin", "schedule", "intervalMinutes", "dailyTimes", "dailyTimesEnabled",
                           "syncOnLaunch", "folders", "localPath", "s3Prefix", "exclude"]

    /// JSON indenté sur 2 espaces ; les tableaux de valeurs simples tiennent sur une ligne.
    public func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
            return String(value)
        case .string(let value): return Self.quote(value)
        case .array(let items):
            if items.isEmpty { return "[]" }
            if items.allSatisfy(\.isScalar) {
                return "[" + items.map { $0.pretty() }.joined(separator: ", ") + "]"
            }
            return "[\n" + items.map { inner + $0.pretty(indent: indent + 2) }.joined(separator: ",\n") + "\n\(pad)]"
        case .object(let dict):
            if dict.isEmpty { return "{}" }
            let keys = dict.keys.sorted { a, b in
                switch (Self.keyOrder.firstIndex(of: a), Self.keyOrder.firstIndex(of: b)) {
                case let (i?, j?): return i < j
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return a < b
                }
            }
            return "{\n" + keys.map { inner + Self.quote($0) + ": " + dict[$0]!.pretty(indent: indent + 2) }
                .joined(separator: ",\n") + "\n\(pad)}"
        }
    }

    private var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Brouillon modifiable (fenêtre de réglages)

/// Un dossier tel qu'affiché dans les réglages.
public struct FolderDraft: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var localPath: String
    /// nil : préfixe par défaut (nom du dossier) ; "" : racine du bucket.
    public var s3Prefix: String?
    /// Motifs d'exclusion, un par ligne.
    public var excludeText: String
    /// Clés inconnues de l'app, conservées telles quelles.
    var extra: [String: JSONValue] = [:]

    public init(localPath: String, s3Prefix: String? = nil, excludeText: String = "") {
        self.localPath = localPath
        self.s3Prefix = s3Prefix
        self.excludeText = excludeText
    }

    init(json: JSONValue) throws {
        guard var dict = json.object else { throw ConfigError.invalid(L10n.tr("each folder must be a JSON object")) }
        guard let path = dict.removeValue(forKey: "localPath")?.string else {
            throw ConfigError.invalid(L10n.tr("each folder needs a “localPath”"))
        }
        localPath = path
        s3Prefix = dict.removeValue(forKey: "s3Prefix")?.string
        if case .array(let items)? = dict.removeValue(forKey: "exclude") {
            excludeText = items.compactMap(\.string).joined(separator: "\n")
        } else {
            excludeText = ""
        }
        extra = dict
    }

    public var excludePatterns: [String] {
        excludeText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var json: JSONValue {
        var dict = extra
        dict["localPath"] = .string(localPath.trimmingCharacters(in: .whitespaces))
        if let s3Prefix { dict["s3Prefix"] = .string(s3Prefix) }
        let patterns = excludePatterns
        if !patterns.isEmpty { dict["exclude"] = .array(patterns.map(JSONValue.string)) }
        return .object(dict)
    }

    /// Nom affiché : dernier composant du chemin.
    public var displayName: String {
        let name = URL(fileURLWithPath: RealHome.expand(localPath)).lastPathComponent
        return name.isEmpty ? "(sans chemin)" : name
    }

    /// Préfixe utilisé si `s3Prefix` est absent.
    public var defaultPrefix: String {
        FolderConfig(localPath: localPath, s3Prefix: nil, exclude: nil).normalizedPrefix
    }

    public static func == (a: FolderDraft, b: FolderDraft) -> Bool {
        a.localPath == b.localPath && a.s3Prefix == b.s3Prefix && a.excludeText == b.excludeText && a.extra == b.extra
    }
}

/// config.json sous forme de champs modifiables. Les clés que l'interface ne connaît pas
/// (sessionToken, secretAccessKey, clés futures…) sont conservées à l'enregistrement.
public struct ConfigDraft: Equatable, Sendable {
    /// "" : absent (profil « default », sauf si une clé d'accès est renseignée).
    public var awsProfile = ""
    public var accessKeyId = ""
    public var region = ""
    public var bucket = ""
    public var deleteRemote = false
    public var launchAtLogin = false
    public var syncOnLaunch = false
    /// 0 : pas de synchro à intervalle régulier.
    public var intervalMinutes = 0
    /// Heures fixes séparées par des virgules ou des espaces : "02:00, 13:30".
    public var dailyTimes = ""
    /// false : heures fixes désactivées (la liste est conservée).
    public var dailyTimesEnabled = true
    public var folders: [FolderDraft] = []

    private var raw: [String: JSONValue] = [:]

    /// config.json contient une clé secrète en clair (conservée, non modifiable ici).
    public var hasPlaintextSecret: Bool { raw["secretAccessKey"]?.string?.isEmpty == false }

    public init() {}

    /// Lit le contenu de config.json, même incomplet (bucket absent, aucun dossier…) ;
    /// seule une erreur de syntaxe JSON est refusée.
    public init(data: Data) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ConfigError.invalid(L10n.tr("unreadable JSON (%@)", error.localizedDescription))
        }
        guard let dict = value.object else { throw ConfigError.invalid(L10n.tr("the file must contain a JSON object")) }
        raw = dict
        func text(_ key: String, in d: [String: JSONValue] = dict) -> String { d[key]?.string ?? "" }
        func flag(_ key: String, in d: [String: JSONValue] = dict) -> Bool {
            if case .bool(let value)? = d[key] { return value }
            return false
        }
        awsProfile = text("awsProfile")
        accessKeyId = text("accessKeyId")
        region = text("region")
        bucket = text("bucket")
        deleteRemote = flag("deleteRemote")
        launchAtLogin = flag("launchAtLogin")
        let schedule = dict["schedule"]?.object ?? [:]
        syncOnLaunch = flag("syncOnLaunch", in: schedule)
        if case .number(let minutes)? = schedule["intervalMinutes"] { intervalMinutes = max(0, Int(minutes)) }
        if case .array(let times)? = schedule["dailyTimes"] {
            dailyTimes = times.compactMap(\.string).joined(separator: ", ")
        }
        if case .bool(false)? = schedule["dailyTimesEnabled"] { dailyTimesEnabled = false }
        if case .array(let items)? = dict["folders"] {
            folders = try items.map(FolderDraft.init(json:))
        }
    }

    public var dailyTimeList: [String] {
        dailyTimes.components(separatedBy: CharacterSet(charactersIn: ",; ").union(.newlines))
            .filter { !$0.isEmpty }
    }

    /// Contenu de config.json, clés inconnues comprises.
    public func encoded() -> Data {
        var dict = raw
        func set(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            dict[key] = trimmed.isEmpty ? nil : .string(trimmed)
        }
        set("awsProfile", awsProfile)
        set("accessKeyId", accessKeyId)
        set("region", region)
        dict["bucket"] = .string(bucket.trimmingCharacters(in: .whitespacesAndNewlines))
        dict["deleteRemote"] = .bool(deleteRemote)
        dict["launchAtLogin"] = .bool(launchAtLogin)
        var schedule = raw["schedule"]?.object ?? [:]
        schedule["intervalMinutes"] = intervalMinutes > 0 ? .number(Double(intervalMinutes)) : nil
        let times = dailyTimeList
        schedule["dailyTimes"] = times.isEmpty ? nil : .array(times.map(JSONValue.string))
        schedule["dailyTimesEnabled"] = dailyTimesEnabled ? nil : .bool(false)
        schedule["syncOnLaunch"] = .bool(syncOnLaunch)
        dict["schedule"] = .object(schedule)
        dict["folders"] = .array(folders.map(\.json))
        return Data((JSONValue.object(dict).pretty() + "\n").utf8)
    }

    /// Vérifie le brouillon avec les mêmes règles qu'au chargement de config.json.
    @discardableResult
    public func validate() throws -> AppConfig {
        try ConfigStore.decode(encoded())
    }

    /// Liste des dossiers en JSON (éditeur brut).
    public var foldersJSON: String {
        JSONValue.array(folders.map(\.json)).pretty()
    }

    /// Remplace la liste des dossiers par le JSON saisi (un tableau d'objets).
    public mutating func setFolders(json: String) throws {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        } catch {
            throw ConfigError.invalid(L10n.tr("unreadable folder JSON (%@)", error.localizedDescription))
        }
        guard case .array(let items) = value else {
            throw ConfigError.invalid(L10n.tr("the folder list must be a JSON array [ … ]"))
        }
        folders = try items.map(FolderDraft.init(json:))
    }
}

extension ConfigStore {
    /// Contenu actuel de config.json (le modèle s'il n'existe pas encore).
    public static func currentData() -> Data {
        (try? Data(contentsOf: configURL)) ?? Data(template.utf8)
    }

    /// Écrit config.json (lisible par l'utilisateur seul : il peut contenir une clé secrète).
    public static func save(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}
