import SwiftUI
import S5Core

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Observé pour rafraîchir les boutons « Se connecter à AWS… » et « Autoriser l'accès… ».
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                loadErrorView(error)
            } else {
                TabView {
                    AccountTab(model: model)
                        .tabItem { Text("Compte AWS") }
                    SyncTab(model: model)
                        .tabItem { Text("Synchro") }
                    FoldersTab(model: model)
                        .tabItem { Text("Dossiers") }
                }
                .padding([.horizontal, .top])
            }
            Divider().padding(.top, 12)
            footer
        }
        .frame(minWidth: 620, minHeight: 500)
    }

    private func loadErrorView(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("config.json ne peut pas être lu", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error).textSelection(.enabled)
            Text("Corrige le fichier dans un éditeur de texte, puis clique « Relire ».")
                .foregroundStyle(.secondary)
            HStack {
                Button("Ouvrir config.json") { model.openConfigFile() }
                Button("Relire") { model.load() }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = model.message {
                Label(message, systemImage: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(model.messageIsError ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.needsAccess {
                Button("Autoriser l'accès…") { model.grantAccess() }
            }
            Button("Ouvrir config.json") { model.openConfigFile() }
            Button("Annuler les modifications") { model.revert() }
                .disabled(!model.isDirty)
            Button("Enregistrer") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.loadError != nil)
        }
        .padding(12)
    }
}

// MARK: - Compte AWS

private struct AccountTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Profil AWS", text: $model.draft.awsProfile, prompt: Text(profilePlaceholder))
                    if !model.profiles.isEmpty {
                        Menu {
                            ForEach(model.profiles, id: \.self) { name in
                                Button(name) { model.draft.awsProfile = name }
                            }
                        } label: {
                            Text("Profils")
                        }
                        .fixedSize()
                    }
                }
                if model.isSSOProfile {
                    HStack {
                        Text("Profil IAM Identity Center (SSO).").foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isLoggingIn ? "Annuler la connexion" : "Se connecter à AWS…") { model.login() }
                    }
                }
            } header: {
                Text("Profil (~/.aws)")
            } footer: {
                Text("Clés, IAM Identity Center (SSO) ou credential_process. Vide : profil « default », "
                     + "sauf si une clé d'accès est renseignée ci-dessous.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Clé d'accès (Access Key ID)", text: $model.draft.accessKeyId, prompt: Text("AKIA…"))
                    .font(.body.monospaced())
                HStack {
                    Text(model.draft.hasPlaintextSecret
                         ? "Une clé secrète est écrite en clair dans config.json (déconseillé)."
                         : "La clé secrète est gardée dans le trousseau macOS.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clé secrète…") { model.editSecretKey() }
                        .disabled(model.draft.accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Clé d'accès (facultatif)")
            } footer: {
                Text("Utilisée seule si le profil est vide, sinon en secours si le profil ne fonctionne pas. "
                     + "Enregistre d'abord pour que la clé d'accès soit prise en compte.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Bucket S3") {
                TextField("Bucket", text: $model.draft.bucket, prompt: Text("mon-bucket"))
                TextField("Région", text: $model.draft.region, prompt: Text("celle du profil (ex. eu-west-3)"))
            }
        }
        .formStyle(.grouped)
    }

    private var profilePlaceholder: String {
        model.draft.accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty ? "default" : "aucun (clé d'accès seule)"
    }
}

// MARK: - Synchro

private struct SyncTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Planification") {
                Toggle("Synchroniser à intervalle régulier", isOn: intervalEnabled)
                if model.draft.intervalMinutes > 0 {
                    HStack {
                        Text("Toutes les")
                        TextField("", value: $model.draft.intervalMinutes, format: .number)
                            .labelsHidden()
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $model.draft.intervalMinutes, in: 1...10_080, step: 5)
                            .labelsHidden()
                        Text("minutes")
                        Spacer()
                    }
                }
                TextField("Heures fixes", text: $model.draft.dailyTimes, prompt: Text("ex. 02:00, 13:30"))
                Toggle("Synchroniser au lancement de l'app", isOn: $model.draft.syncOnLaunch)
            }

            Section {
                Toggle("Supprimer sur S3 les fichiers supprimés en local", isOn: $model.draft.deleteRemote)
            } header: {
                Text("Suppressions")
            } footer: {
                Text("Jamais pour un dossier envoyé à la racine du bucket, ni pour un dossier local vide.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Démarrage") {
                Toggle("Lancer Simple Sync S3 à l'ouverture de session", isOn: $model.draft.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    private var intervalEnabled: Binding<Bool> {
        Binding(get: { model.draft.intervalMinutes > 0 },
                set: { model.draft.intervalMinutes = $0 ? 60 : 0 })
    }
}

// MARK: - Dossiers

private struct FoldersTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Affichage", selection: Binding(get: { model.folderMode }, set: { model.setFolderMode($0) })) {
                ForEach(SettingsModel.FolderMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            switch model.folderMode {
            case .list: listEditor
            case .json: jsonEditor
            }
        }
        .padding()
    }

    private var listEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(model.draft.folders) { folder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayName)
                            Text(folder.localPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .tag(folder.id)
                    }
                    .onMove { model.draft.folders.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                HStack(spacing: 0) {
                    Button { model.addFolders() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                        .help("Ajouter des dossiers")
                    Button { model.removeSelectedFolder() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .help("Retirer le dossier de la liste (rien n'est supprimé)")
                        .disabled(model.selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .frame(width: 220)

            if let id = model.selection, let folder = binding(for: id) {
                FolderDetail(folder: folder, choose: { model.chooseFolder(for: id) })
            } else {
                VStack {
                    Spacer()
                    Text(model.draft.folders.isEmpty ? "Aucun dossier : clique « + » pour en ajouter."
                                                     : "Sélectionne un dossier.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func binding(for id: FolderDraft.ID) -> Binding<FolderDraft>? {
        guard model.draft.folders.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.draft.folders.first { $0.id == id } ?? FolderDraft(localPath: "") },
            set: { newValue in
                if let index = model.draft.folders.firstIndex(where: { $0.id == id }) {
                    model.draft.folders[index] = newValue
                }
            })
    }

    private var jsonEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $model.foldersJSON)
                .font(.body.monospaced())
                .border(Color.secondary.opacity(0.3))
            Text("Tableau d'objets : localPath (obligatoire), s3Prefix, exclude. "
                 + "Vérifié au retour en mode Liste et à l'enregistrement.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FolderDetail: View {
    @Binding var folder: FolderDraft
    let choose: () -> Void

    var body: some View {
        Form {
            HStack {
                TextField("Dossier local", text: $folder.localPath, prompt: Text("~/Documents/…"))
                Button("Choisir…", action: choose)
            }
            Toggle("Envoyer à la racine du bucket", isOn: atRoot)
            TextField("Préfixe S3", text: prefix, prompt: Text(folder.defaultPrefix.isEmpty ? "racine" : folder.defaultPrefix))
                .disabled(folder.s3Prefix == "")
            VStack(alignment: .leading, spacing: 4) {
                Text("Exclusions (une par ligne, syntaxe .gitignore)")
                TextEditor(text: $folder.excludeText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.3))
                Text("Ex. *.tmp, node_modules/, /build, !garder.log")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var atRoot: Binding<Bool> {
        Binding(get: { folder.s3Prefix == "" },
                set: { folder.s3Prefix = $0 ? "" : nil })
    }

    /// Champ vide : préfixe par défaut (nom du dossier).
    private var prefix: Binding<String> {
        Binding(get: { folder.s3Prefix ?? "" },
                set: { folder.s3Prefix = $0.isEmpty ? nil : $0 })
    }
}
