import AppKit
import SwiftUI
import S5Core

/// Fenêtre de réglages, gérée à la main : la scène `Settings` de SwiftUI s'ouvre mal depuis une app
/// de barre de menus (pas de Dock, pas de menu principal visible) selon la version de macOS.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var model: SettingsModel?

    func show(state: AppState) {
        if window == nil {
            let model = SettingsModel(state: state)
            let window = EditingWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                       backing: .buffered, defer: false)
            window.title = L10n.tr("Simple Sync S3 Settings")
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model, state: state))
            window.setContentSize(NSSize(width: 680, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.model = model
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        sender.makeFirstResponder(nil)
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Save your changes?")
        alert.informativeText = L10n.tr("The changed settings have not been written to config.json yet.")
        alert.addButton(withTitle: L10n.tr("Save"))
        alert.addButton(withTitle: L10n.tr("Cancel"))
        alert.addButton(withTitle: L10n.tr("Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return model.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Réouverture = relecture de config.json.
        window = nil
        model = nil
    }
}

/// L'app n'a pas de menu Édition visible : on relaie ⌘X/C/V/A/Z aux champs de texte.
private final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
                || event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == [.command, .shift],
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let shift = event.modifierFlags.contains(.shift)
            let action: Selector? = switch (key, shift) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            case ("w", false): #selector(NSWindow.performClose(_:))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}
