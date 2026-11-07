import SwiftUI
import AppKit
import S5Core

@main
struct SimpleSyncS3App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        if state.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if state.hasError { return "exclamationmark.icloud" }
        return "icloud.and.arrow.up"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pas d'icône dans le Dock, même lancé via `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.status)
            .monospacedDigit()
        if let error = state.configError {
            Text(error)
        }
        if let date = state.lastSync {
            Text("Dernière synchro : \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if let report = state.lastReport {
            Text(report.summary)
        }
        if !state.missingAccess.isEmpty {
            Text("Accès à autoriser : \(state.missingAccess.count) dossier(s)")
        }

        Divider()

        Button(state.isSyncing ? "Arrêter la synchro" : "Synchroniser maintenant") {
            state.syncNowOrCancel()
        }
        .keyboardShortcut("s")

        Button("Réglages…") { state.openSettings() }
            .keyboardShortcut(",")
        Button("Ouvrir config.json") { state.openConfig() }
        Button("Recharger la configuration") { state.reloadConfig() }
            .keyboardShortcut("r")
        Button("Ouvrir le journal") { state.openLog() }
        Button("Enregistrer la clé secrète AWS…") { state.editSecretKey() }
        if state.ssoProfile != nil {
            Button(state.isLoggingIn ? "Annuler la connexion à AWS" : "Se connecter à AWS…") { state.loginOrCancel() }
        }
        if !state.missingAccess.isEmpty {
            Button("Autoriser l'accès…") { state.grantAccess() }
        }

        Divider()

        if let help = Bundle.main.url(forResource: "Aide", withExtension: "html") {
            Button("Aide") { NSWorkspace.shared.open(help) }
        }
        Button("Quitter Simple Sync S3") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
