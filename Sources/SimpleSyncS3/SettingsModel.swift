import AppKit
import S5Core

/// État de la fenêtre de réglages : un brouillon de config.json, enregistré à la demande.
@MainActor
final class SettingsModel: ObservableObject {
    enum FolderMode: String, CaseIterable, Identifiable {
        case list = "Liste"
        case json = "JSON"
        var id: String { rawValue }
    }

    @Published var draft = ConfigDraft()
    @Published private(set) var original = ConfigDraft()
    /// config.json illisible (erreur de syntaxe) : la fenêtre ne propose que de l'ouvrir dans un éditeur.
    @Published private(set) var loadError: String?
    @Published var message: String?
    @Published var messageIsError = false
    @Published var selection: FolderDraft.ID?
    @Published private(set) var folderMode = FolderMode.list
    @Published var foldersJSON = ""
    @Published private(set) var profiles: [String] = []

    private unowned let state: AppState

    init(state: AppState) {
        self.state = state
        load()
    }

    var isDirty: Bool {
        draft != original || (folderMode == .json && foldersJSON != draft.foldersJSON)
    }

    var isSSOProfile: Bool {
        let profile = draft.awsProfile.trimmingCharacters(in: .whitespaces)
        return state.ssoProfile != nil && state.ssoProfile == (profile.isEmpty ? "default" : profile)
    }

    func load() {
        do {
            let loaded = try ConfigDraft(data: ConfigStore.currentData())
            draft = loaded
            original = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        foldersJSON = draft.foldersJSON
        selection = draft.folders.first?.id
        profiles = AWSProfiles.names()
        message = nil
    }

    func revert() {
        load()
    }

    // MARK: - Dossiers

    func setFolderMode(_ mode: FolderMode) {
        guard mode != folderMode else { return }
        if mode == .json {
            foldersJSON = draft.foldersJSON
        } else {
            guard applyFoldersJSON() else { return }
            selection = draft.folders.first?.id
        }
        folderMode = mode
    }

    /// Reporte le JSON saisi dans le brouillon. Faux (avec un message) s'il est invalide.
    private func applyFoldersJSON() -> Bool {
        guard folderMode == .json, foldersJSON != draft.foldersJSON else { return true }
        do {
            try draft.setFolders(json: foldersJSON)
            return true
        } catch {
            show(error.localizedDescription, isError: true)
            return false
        }
    }

    func addFolders() {
        let panel = folderPanel(message: "Choisis un ou plusieurs dossiers à synchroniser.", prompt: "Ajouter")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added: FolderDraft.ID?
        for url in panel.urls {
            let path = Self.displayPath(url)
            if draft.folders.contains(where: { RealHome.expand($0.localPath) == url.path }) { continue }
            grantIfSandboxed(url)
            let folder = FolderDraft(localPath: path)
            draft.folders.append(folder)
            added = added ?? folder.id
        }
        if let added { selection = added }
    }

    func chooseFolder(for id: FolderDraft.ID) {
        guard let index = draft.folders.firstIndex(where: { $0.id == id }) else { return }
        let panel = folderPanel(message: "Choisis le dossier à synchroniser.", prompt: "Choisir")
        let current = RealHome.expand(draft.folders[index].localPath)
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        grantIfSandboxed(url)
        draft.folders[index].localPath = Self.displayPath(url)
    }

    func removeSelectedFolder() {
        guard let selection, let index = draft.folders.firstIndex(where: { $0.id == selection }) else { return }
        draft.folders.remove(at: index)
        self.selection = draft.folders.isEmpty ? nil : draft.folders[min(index, draft.folders.count - 1)].id
    }

    private func folderPanel(message: String, prompt: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = RealHome.url
        return panel
    }

    /// Sous sandbox, le dossier choisi dans le panneau est autorisé tout de suite (signet conservé).
    private func grantIfSandboxed(_ url: URL) {
        guard Sandbox.isActive else { return }
        do {
            try AccessGrants.shared.grant(url)
            Log.info("Accès autorisé : \(url.path)")
        } catch {
            Log.info("Autorisation impossible pour \(url.path) : \(error.localizedDescription)")
        }
    }

    /// Chemin écrit dans config.json : « ~/… » sous le dossier personnel.
    static func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = RealHome.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Enregistrement

    @discardableResult
    func save() -> Bool {
        // Valide le champ en cours d'édition (les champs numériques ne sont repris qu'à la fin de la saisie).
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard applyFoldersJSON() else { return false }
        do {
            try draft.validate()
            try ConfigStore.save(draft.encoded())
        } catch {
            show(error.localizedDescription, isError: true)
            return false
        }
        Log.info("Configuration enregistrée depuis les réglages")
        state.reloadConfig()
        let selected = draft.folders.firstIndex { $0.id == selection }
        load()
        if let selected, selected < draft.folders.count { selection = draft.folders[selected].id }
        if Sandbox.isActive && !state.missingAccess.isEmpty {
            show("Enregistré. Des dossiers restent à autoriser : bouton « Autoriser l'accès… ».", isError: false)
        } else {
            show("Configuration enregistrée.", isError: false)
        }
        return true
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    // MARK: - Actions déléguées au menu

    func editSecretKey() {
        let key = draft.accessKeyId.trimmingCharacters(in: .whitespaces)
        state.editSecretKey(accessKeyId: key.isEmpty ? nil : key)
    }

    func login() { state.loginOrCancel() }
    func openConfigFile() { state.openConfig() }

    func grantAccess() {
        state.grantAccess()
        // Les profils deviennent lisibles une fois ~/.aws autorisé.
        DispatchQueue.main.async { self.profiles = AWSProfiles.names() }
    }

    var needsAccess: Bool { Sandbox.isActive && !state.missingAccess.isEmpty }
    var isLoggingIn: Bool { state.isLoggingIn }
}
