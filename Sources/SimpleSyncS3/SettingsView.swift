import SwiftUI
import S5Core

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Observé pour rafraîchir les boutons « Sign In to AWS… » et « Grant Access… ».
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                loadErrorView(error)
            } else {
                TabView {
                    AccountTab(model: model)
                        .tabItem { Text("AWS Account") }
                    SyncTab(model: model)
                        .tabItem { Text("Sync") }
                    FoldersTab(model: model)
                        .tabItem { Text("Folders") }
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
            Label("config.json can’t be read", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error).textSelection(.enabled)
            Text("Fix the file in a text editor, then click “Reload”.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open config.json") { model.openConfigFile() }
                Button("Reload") { model.load() }
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
                Button("Grant Access…") { model.grantAccess() }
            }
            Button("Open config.json") { model.openConfigFile() }
            Button("Revert Changes") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
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
                    TextField("AWS profile", text: $model.draft.awsProfile, prompt: profilePlaceholder)
                    if !model.profiles.isEmpty {
                        Menu {
                            ForEach(model.profiles, id: \.self) { name in
                                Button(name) { model.draft.awsProfile = name }
                            }
                        } label: {
                            Text("Profiles")
                        }
                        .fixedSize()
                    }
                }
                if model.isSSOProfile {
                    HStack {
                        Text("IAM Identity Center (SSO) profile.").foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isLoggingIn ? "Cancel Sign-In" : "Sign In to AWS…") { model.login() }
                    }
                }
            } header: {
                Text("Profile (~/.aws)")
            } footer: {
                Text("Keys, IAM Identity Center (SSO) or credential_process. Empty: the “default” profile, unless an access key is entered below.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Access key ID", text: $model.draft.accessKeyId, prompt: Text(verbatim: "AKIA…"))
                    .font(.body.monospaced())
                HStack {
                    Text(model.draft.hasPlaintextSecret
                         ? "A secret key is stored in plain text in config.json (not recommended)."
                         : "The secret key is kept in the macOS Keychain.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Secret Key…") { model.editSecretKey() }
                        .disabled(model.draft.accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Access key (optional)")
            } footer: {
                Text("Used on its own if the profile is empty, otherwise as a fallback when the profile doesn’t work. Save first so the access key is taken into account.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("S3 Bucket") {
                TextField("Bucket", text: $model.draft.bucket, prompt: Text("my-bucket"))
                TextField("Region", text: $model.draft.region, prompt: Text("from the profile (e.g. eu-west-3)"))
            }
        }
        .formStyle(.grouped)
    }

    private var profilePlaceholder: Text {
        model.draft.accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty
            ? Text(verbatim: "default") : Text("none (access key only)")
    }
}

// MARK: - Synchro

private struct SyncTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Schedule") {
                Toggle("Sync at regular intervals", isOn: intervalEnabled)
                if model.draft.intervalMinutes > 0 {
                    HStack {
                        Text("Every")
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
                TextField("Fixed times", text: $model.draft.dailyTimes, prompt: Text("e.g. 02:00, 13:30"))
                Toggle("Sync when the app launches", isOn: $model.draft.syncOnLaunch)
            }

            Section {
                Toggle("Delete from S3 the files deleted locally", isOn: $model.draft.deleteRemote)
            } header: {
                Text("Deletions")
            } footer: {
                Text("Never for a folder synced to the bucket root, nor for an empty local folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Simple Sync S3 at login", isOn: $model.draft.launchAtLogin)
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
            Picker("View", selection: Binding(get: { model.folderMode }, set: { model.setFolderMode($0) })) {
                ForEach(SettingsModel.FolderMode.allCases) { Text($0.title).tag($0) }
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
                        .help("Add folders")
                    Button { model.removeSelectedFolder() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                        .help("Remove the folder from the list (nothing is deleted)")
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
                    Text(model.draft.folders.isEmpty ? "No folders: click “+” to add one."
                                                     : "Select a folder.")
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
            Text("Array of objects: localPath (required), s3Prefix, exclude. Checked when switching back to List and when saving.")
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
                TextField("Local folder", text: $folder.localPath, prompt: Text(verbatim: "~/Documents/…"))
                Button("Choose…", action: choose)
            }
            Toggle("Upload to the bucket root", isOn: atRoot)
            TextField("S3 prefix", text: prefix, prompt: folder.defaultPrefix.isEmpty ? Text("root") : Text(verbatim: folder.defaultPrefix))
                .disabled(folder.s3Prefix == "")
            VStack(alignment: .leading, spacing: 4) {
                Text("Exclusions (one per line, .gitignore syntax)")
                TextEditor(text: $folder.excludeText)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.3))
                Text("E.g. *.tmp, node_modules/, /build, !keep.log")
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
