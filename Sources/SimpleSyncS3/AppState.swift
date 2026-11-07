import AppKit
import S5Core
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status = "Prêt"
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var configError: String?
    /// Sous sandbox : dossiers utilisés par la configuration et pas encore autorisés.
    @Published private(set) var missingAccess: [String] = []
    /// Profil IAM Identity Center de la configuration, s'il y en a un.
    @Published private(set) var ssoProfile: String?
    @Published private(set) var isLoggingIn = false

    var hasError: Bool {
        configError != nil || !(lastReport?.errors.isEmpty ?? true) || !missingAccess.isEmpty
    }

    private var config: AppConfig?
    private var scheduler = Scheduler()
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var loginCancel: CancelFlag?
    /// Date de modification de config.json au dernier chargement.
    private var configDate: Date?

    init() {
        Log.info("Démarrage de Simple Sync S3" + (Sandbox.isActive ? " (sandbox)" : ""))
        // Avant tout accès à la configuration ou aux autorisations (AccessGrants.shared).
        ConfigStore.migrateLegacyDirectory()
        if Sandbox.isActive {
            for failure in AccessGrants.shared.activateAll() { Log.info("Autorisation d'accès : \(failure)") }
        }
        reloadConfig()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if config?.schedule.syncOnLaunch == true {
            startSync(reason: "démarrage")
        }
    }

    // MARK: - Actions du menu

    func syncNowOrCancel() {
        if isSyncing {
            syncTask?.cancel()
            status = "Arrêt en cours…"
            return
        }
        reloadConfigIfChanged()
        guard config != nil else {
            let message = configError ?? "Configuration absente"
            Log.info("Synchro manuelle impossible : \(message)")
            // Laisse le menu se refermer avant d'ouvrir une fenêtre modale.
            DispatchQueue.main.async {
                self.showAlert("Synchro impossible : configuration à corriger",
                               message + "\n\nCorrige la configuration (menu « Réglages… ») puis relance la synchro.")
            }
            return
        }
        startSync(reason: "manuelle")
    }

    /// Recharge config.json s'il a été modifié depuis le dernier chargement (avant chaque synchro,
    /// pour qu'une modification soit prise en compte même sans « Recharger la configuration »).
    private func reloadConfigIfChanged() {
        if Self.configModificationDate() != configDate { reloadConfig() }
    }

    private static func configModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: ConfigStore.configURL.path))?[.modificationDate] as? Date
    }

    func reloadConfig() {
        defer { configDate = Self.configModificationDate() }
        do {
            let loaded = try ConfigStore.load()
            config = loaded
            configError = nil
            status = "Prêt"
            applyLaunchAtLogin(loaded.launchAtLogin)
            Log.info("Configuration chargée : \(loaded.folders.count) dossier(s) → s3://\(loaded.bucket)")
        } catch {
            config = nil
            configError = error.localizedDescription
            status = "Configuration à corriger"
            Log.info(error.localizedDescription)
        }
        refreshAccess()
    }

    /// Met à jour les dossiers à autoriser (sandbox) et le profil SSO éventuel.
    private func refreshAccess() {
        missingAccess = Sandbox.isActive ? (config.map(AccessGrants.shared.missing(for:)) ?? []) : []
        ssoProfile = config?.awsProfile.flatMap { SSOLogin.isSSOProfile($0) ? $0 : nil }
    }

    // MARK: - Sandbox : autorisation des dossiers

    /// Demande, dossier par dossier, l'autorisation d'accès (~/.aws puis les dossiers à synchroniser).
    func grantAccess() {
        DispatchQueue.main.async { self.runGrantPanels() }
    }

    private func runGrantPanels() {
        NSApp.activate(ignoringOtherApps: true)
        for path in missingAccess {
            // Un dossier choisi plus tôt (un parent par exemple) peut déjà couvrir celui-ci.
            if AccessGrants.shared.covers(path) { continue }
            let panel = NSOpenPanel()
            panel.message = "Simple Sync S3 a besoin d'accéder à « \(path) ». Sélectionne ce dossier puis clique « Autoriser »."
            panel.prompt = "Autoriser"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.canCreateDirectories = false
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            guard panel.runModal() == .OK, let url = panel.url else { break }
            do {
                try AccessGrants.shared.grant(url)
                Log.info("Accès autorisé : \(url.path)")
            } catch {
                Log.info("Autorisation impossible pour \(url.path) : \(error.localizedDescription)")
                showAlert("Autorisation impossible", error.localizedDescription)
            }
        }
        refreshAccess()
        if !missingAccess.isEmpty {
            Log.info("Toujours sans accès : " + missingAccess.joined(separator: ", "))
        }
    }

    // MARK: - IAM Identity Center

    /// Ouvre le navigateur pour se connecter à IAM Identity Center, ou annule la connexion en cours.
    func loginOrCancel() {
        if let loginCancel {
            loginCancel.cancel()
            return
        }
        guard let profile = ssoProfile else { return }
        let flag = CancelFlag()
        loginCancel = flag
        isLoggingIn = true
        status = "Connexion à AWS…"
        // Attente bloquante (jusqu'à la validation dans le navigateur) : hors du pool de tâches Swift.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<Void, Error> {
                try SSOLogin.login(profile: profile, open: { authorization in
                    Log.info("Connexion IAM Identity Center : code \(authorization.userCode), "
                             + "à valider sur \(authorization.verificationURL.absoluteString)")
                    Task { @MainActor in
                        self.status = "Code \(authorization.userCode) : valide-le dans le navigateur"
                        NSWorkspace.shared.open(authorization.verificationURL)
                    }
                }, isCancelled: { flag.isCancelled })
            }
            Task { @MainActor in self.finishLogin(result) }
        }
    }

    private func finishLogin(_ result: Result<Void, Error>) {
        let cancelled = loginCancel?.isCancelled ?? false
        loginCancel = nil
        isLoggingIn = false
        switch result {
        case .success:
            status = "Connecté à AWS"
        case .failure(let error):
            Log.info(error.localizedDescription)
            status = cancelled ? "Connexion AWS annulée" : "Connexion AWS échouée"
            if !cancelled { showAlert("Connexion à AWS", error.localizedDescription) }
        }
    }

    func openSettings() {
        // Laisse le menu se refermer avant d'ouvrir la fenêtre.
        DispatchQueue.main.async { SettingsWindowController.shared.show(state: self) }
    }

    func openConfig() {
        if !FileManager.default.fileExists(atPath: ConfigStore.configURL.path) { reloadConfig() }
        NSWorkspace.shared.open(ConfigStore.configURL)
    }

    func openLog() {
        if FileManager.default.fileExists(atPath: Log.fileURL.path) {
            NSWorkspace.shared.open(Log.fileURL)
        }
    }

    /// Saisie de la clé secrète AWS associée à `accessKeyId` (par défaut celle de la configuration chargée),
    /// enregistrée dans le trousseau.
    func editSecretKey(accessKeyId: String? = nil) {
        // Laisse le menu se refermer avant d'ouvrir une fenêtre modale.
        DispatchQueue.main.async { self.runSecretKeyAlert(accessKeyId: accessKeyId) }
    }

    private func runSecretKeyAlert(accessKeyId explicit: String?) {
        guard let accessKeyId = explicit ?? config?.accessKeyId else {
            if config == nil {
                showAlert("Configuration à corriger", configError ?? "Configuration absente")
            } else {
                showAlert("Aucune clé d'accès configurée",
                          "Renseigne la clé d'accès dans « Réglages… » (onglet Compte AWS), puis enregistre.")
            }
            return
        }
        let store = KeychainSecretStore()
        let exists = store.hasSecret(for: accessKeyId)

        let alert = NSAlert()
        alert.messageText = "Clé secrète AWS"
        alert.informativeText = "Clé d'accès : \(accessKeyId)\n"
            + (exists ? "Une clé secrète est déjà dans le trousseau ; la saisie la remplace."
                      : "La clé secrète sera enregistrée dans le trousseau macOS.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Clé secrète"
        alert.accessoryView = field
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        if exists { alert.addButton(withTitle: "Supprimer la clé du trousseau") }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        let masked = AccessKey.masked(accessKeyId)
        do {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let secret = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !secret.isEmpty else { return }
                try store.save(secret, for: accessKeyId)
                status = "Clé secrète enregistrée"
                Log.info("Clé secrète enregistrée dans le trousseau pour \(masked)")
            case .alertThirdButtonReturn:
                try store.delete(for: accessKeyId)
                status = "Clé secrète supprimée"
                Log.info("Clé secrète supprimée du trousseau pour \(masked)")
            default:
                break
            }
        } catch {
            Log.info(error.localizedDescription)
            showAlert("Trousseau", error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Synchro

    private func tick() {
        guard !isSyncing else { return }
        reloadConfigIfChanged()
        guard let config else { return }
        if let reason = scheduler.shouldSync(schedule: config.schedule) {
            startSync(reason: reason)
        }
    }

    private func startSync(reason: String) {
        guard !isSyncing else { return }
        guard let config else {
            status = configError ?? "Configuration absente"
            Log.info("Synchro (\(reason)) impossible : \(status)")
            return
        }
        isSyncing = true
        scheduler.didStartSync()
        status = "Synchronisation…"
        Log.info("Synchro lancée (\(reason))")

        // AppState vit aussi longtemps que l'app : la capture forte de self est sans conséquence.
        // Au plus une mise à jour toutes les 2 s : chaque changement redessine le menu ouvert.
        let throttle = Throttle(interval: 2)
        syncTask = Task {
            let report = await Self.runEngine(config: config) { message in
                guard throttle.allow() else { return }
                Task { @MainActor in self.status = message }
            }
            finish(report)
        }
    }

    /// Exécutée hors du thread principal (fonction async non isolée).
    private nonisolated static func runEngine(config: AppConfig,
                                              progress: @escaping @Sendable (String) -> Void) async -> SyncReport {
        do {
            return try await SyncEngine(config: config, progress: progress).run()
        } catch {
            var failed = SyncReport()
            failed.errors.append(error.localizedDescription)
            return failed
        }
    }

    private func finish(_ report: SyncReport) {
        scheduler.didFinishSync()
        isSyncing = false
        syncTask = nil
        lastSync = Date()
        lastReport = report
        status = report.errors.isEmpty ? "À jour" : "Terminé avec des erreurs"
        Log.info("Synchro terminée : \(report.summary)")
        for error in report.errors { Log.info("  • \(error)") }
    }

    // MARK: - Lancement à l'ouverture de session

    private func applyLaunchAtLogin(_ enabled: Bool) {
        // Ne fonctionne que depuis le bundle .app (pas via `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            Log.info("Lancement à l'ouverture de session : \(error.localizedDescription)")
        }
    }
}

/// Drapeau d'annulation partagé avec la connexion SSO qui tourne en arrière-plan.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Laisse passer au plus un appel par intervalle (appelé depuis la tâche de synchro).
final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func allow(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}
