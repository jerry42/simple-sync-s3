import Foundation

/// Messages de progression affichés dans le menu. Leur largeur ne doit pas varier pendant la synchro
/// d'un dossier (le menu suit la largeur du texte) : pourcentage sur 3 caractères et compteur sur la
/// largeur du total, complétés par des espaces de chiffre (U+2007, même largeur qu'un chiffre).
public enum SyncProgress {
    static let figureSpace = "\u{2007}"

    /// « Dropbox :  37 % ( 120 / 1234) » : `done` fichiers traités sur `total` (espaces de chiffre en tête).
    public static func files(folder: String, done: Int, total: Int) -> String {
        let percent = total > 0 ? min(100, done * 100 / total) : 100
        let totalText = String(total)
        return "\(folder) : \(pad(String(percent), to: 3)) % (\(pad(String(done), to: totalText.count)) / \(totalText))"
    }

    static func pad(_ text: String, to width: Int) -> String {
        String(repeating: figureSpace, count: max(0, width - text.count)) + text
    }
}
