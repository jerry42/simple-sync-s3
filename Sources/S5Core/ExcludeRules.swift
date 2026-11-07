import Foundation

/// Motifs d'exclusion avec la sémantique de `.gitignore`, relatifs au dossier synchronisé.
///
/// - sans « / » (hors « / » final) : correspond au nom à n'importe quelle profondeur ;
/// - avec un « / » au début ou au milieu : ancré à la racine, `*`, `?` et `[…]` ne traversent pas « / » ;
/// - `**/x`, `x/**`, `a/**/b` : n'importe quelle profondeur, tout le contenu, zéro ou plusieurs dossiers ;
/// - « / » final : dossiers uniquement (donc tout leur contenu) ;
/// - `!motif` : ré-inclusion, le dernier motif qui correspond gagne ; impossible sous un dossier exclu ;
/// - lignes vides et `#…` ignorées, `\#` et `\!` échappés.
public struct ExcludeRules: Sendable {
    static let defaults = [".DS_Store", "._*", ".localized", "Icon\r",
                           ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems"]

    private struct Rule: Sendable {
        let negated: Bool
        let directoryOnly: Bool
        let anchored: Bool
        /// Motif découpé sur « / » ; un seul élément pour un motif non ancré.
        let segments: [String]
    }

    private let rules: [Rule]

    public init(_ patterns: [String], includeDefaults: Bool = true) {
        rules = ((includeDefaults ? Self.defaults : []) + patterns).compactMap(Self.parse)
    }

    /// Exclu lui-même ou parce qu'un dossier parent est exclu.
    public func isExcluded(_ relativePath: String, isDirectory: Bool) -> Bool {
        let components = Self.components(relativePath)
        for depth in components.indices.dropLast() where matches(components[...depth], isDirectory: true) {
            return true
        }
        return matches(components[...], isDirectory: isDirectory)
    }

    /// Ne regarde que le chemin lui-même, pas ses parents : suffit pendant un scan qui n'entre pas
    /// dans les dossiers exclus (rien n'y serait ré-inclus, comme avec git).
    public func excludesItem(_ relativePath: String, isDirectory: Bool) -> Bool {
        matches(Self.components(relativePath)[...], isDirectory: isDirectory)
    }

    // MARK: - Correspondance

    private func matches(_ components: ArraySlice<String>, isDirectory: Bool) -> Bool {
        guard let name = components.last else { return false }
        var excluded = false
        for rule in rules where rule.negated == excluded {
            if rule.directoryOnly && !isDirectory { continue }
            let hit = rule.anchored
                ? Self.match(rule.segments[...], components)
                : fnmatch(rule.segments[0], name, 0) == 0
            if hit { excluded = !rule.negated }
        }
        return excluded
    }

    private static func match(_ segments: ArraySlice<String>, _ components: ArraySlice<String>) -> Bool {
        guard let segment = segments.first else { return components.isEmpty }
        let rest = segments.dropFirst()
        if segment == "**" {
            // « x/** » : le contenu de x, pas x lui-même (sinon « !x/garder » serait impossible).
            if rest.isEmpty { return !components.isEmpty }
            var tail = components
            while true {
                if match(rest, tail) { return true }
                if tail.isEmpty { return false }
                tail = tail.dropFirst()
            }
        }
        guard let component = components.first, fnmatch(segment, component, 0) == 0 else { return false }
        return match(rest, components.dropFirst())
    }

    // MARK: - Lecture des motifs

    /// Noms de fichiers macOS souvent en NFD, motifs de config.json en NFC : on compare en NFC.
    private static func components(_ path: String) -> [String] {
        path.precomposedStringWithCanonicalMapping.split(separator: "/").map(String.init)
    }

    private static func parse(_ line: String) -> Rule? {
        var pattern = Substring(line.precomposedStringWithCanonicalMapping)
        // Espaces finaux ignorés sauf s'ils sont échappés (« \ »).
        while pattern.hasSuffix(" ") && !pattern.hasSuffix("\\ ") { pattern = pattern.dropLast() }
        if pattern.isEmpty || pattern.hasPrefix("#") { return nil }

        let negated = pattern.hasPrefix("!")
        if negated {
            pattern = pattern.dropFirst()
        } else if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") {
            pattern = pattern.dropFirst()
        }

        let directoryOnly = pattern.hasSuffix("/")
        while pattern.hasSuffix("/") { pattern = pattern.dropLast() }
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern = pattern.drop(while: { $0 == "/" }) }
        guard !pattern.isEmpty else { return nil }

        let segments = anchored
            ? pattern.split(separator: "/").map(String.init)
            : [String(pattern)]
        return Rule(negated: negated, directoryOnly: directoryOnly, anchored: anchored, segments: segments)
    }
}
