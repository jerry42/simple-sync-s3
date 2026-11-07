import Foundation

/// User-facing texts. The key is the English text; translations live in the app bundle
/// (`Resources/<language>.lproj/Localizable.strings`, copied by `scripts/build-app.sh`).
/// Without a bundle (`swift run`, the `s5-sync` command, unit tests) the English key is used as is.
/// Log messages are not localized: they stay in English.
public enum L10n {
    public static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    /// `key` is a `String(format:)` format: `%@` for strings, `%lld` for integers.
    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }
}
