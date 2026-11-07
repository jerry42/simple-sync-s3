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
            Text("Last sync: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if let report = state.lastReport {
            Text(report.summary)
        }
        if !state.missingAccess.isEmpty {
            Text("Folders needing access: \(state.missingAccess.count)")
        }

        Divider()

        Button(state.isSyncing ? "Stop Sync" : "Sync Now") {
            state.syncNowOrCancel()
        }
        .keyboardShortcut("s")

        Button("Settings…") { state.openSettings() }
            .keyboardShortcut(",")
        Button("Open config.json") { state.openConfig() }
        Button("Reload Configuration") { state.reloadConfig() }
            .keyboardShortcut("r")
        Button("Open Log") { state.openLog() }
        Button("Save AWS Secret Key…") { state.editSecretKey() }
        if state.ssoProfile != nil {
            Button(state.isLoggingIn ? "Cancel AWS Sign-In" : "Sign In to AWS…") { state.loginOrCancel() }
        }
        if !state.missingAccess.isEmpty {
            Button("Grant Access…") { state.grantAccess() }
        }

        Divider()

        // Page d'aide dans la langue de l'interface (Resources/<langue>.lproj/Help.html).
        if let help = Bundle.main.url(forResource: "Help", withExtension: "html") {
            Button("Help") { NSWorkspace.shared.open(help) }
        }
        Button("Quit Simple Sync S3") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
