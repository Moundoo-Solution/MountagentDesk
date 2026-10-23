import MountagentDeskKit
import SwiftUI

// MARK: - Settings → Servers

struct ServersSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Server?
    @State private var editingCredential: ServerCredential?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { server in
                ServerRow(server: server, projects: model.projects.filter { $0.serverIDs.contains(server.id) }) {
                    editing = server
                }
            }
            HStack(spacing: 8) {
                DashedButton(title: "Add Server…", symbol: "plus.circle.fill") {
                    editing = Server(name: "", host: "")
                }
                DashedButton(title: "Import from SSH Config…", symbol: "square.and.arrow.down") {
                    importing = true
                }
            }
            CredentialsSection { editingCredential = $0 }
                .padding(.top, 16)
            SnippetsSection()
                .padding(.top, 16)
            Text("Agents never get the passwords kept here. When you let one read a server, it asks the app with `\(ServerHelper.commandName) <server> '<command>'`; the app refuses anything that isn't read-only, runs the command over ssh itself (only to hosts already in known_hosts) and logs every call to server-audit.log. An agent with full access still runs as you and could read the key files in ~/.ssh, so for a guarantee on the server itself, give that SSH user (and its database role) read-only rights.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Agent Log in Finder") {
                let log = model.dataRoot.appendingPathComponent("server-audit.log")
                if FileManager.default.fileExists(atPath: log.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                } else {
                    NSWorkspace.shared.open(model.dataRoot)
                }
            }
            .controlSize(.small)
        }
        .sheet(item: $editing) { server in
            ServerEditor(server: server)
        }
        .sheet(item: $editingCredential) { credential in
            CredentialEditor(credential: credential)
        }
        .sheet(isPresented: $importing) {
            SSHImportSheet()
        }
    }
}

/// An "add" button drawn as a dashed outline, as in Settings → Git.
private struct DashedButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(SettingsPane.servers.tint)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One server in Settings: address, credential, agent access and the projects using it.
private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let projects: [Project]
    let edit: () -> Void

    var body: some View {
        let login = model.login(for: server)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 15))
                .foregroundStyle(server.environment.tint)
                .frame(width: 36, height: 36)
                .background(server.environment.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text(login.destination + (server.port.map { ":\($0)" } ?? ""))
                    .font(Theme.Font.toolTarget)
                    .foregroundStyle(Theme.textSecondary)
                Label(login.credential?.name ?? "SSH config / default key", systemImage: "key")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Label(server.aiReadAccess ? "Agents may read" : "Agents can't reach it", systemImage: server.aiReadAccess ? "eye" : "lock")
                    .font(Theme.Font.caption)
                    .foregroundStyle(server.aiReadAccess ? Theme.warning : Theme.textTertiary)
                if !projects.isEmpty {
                    Text("Used by " + projects.map(\.name).joined(separator: ", "))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            Button("Edit…", action: edit)
        }
        .padding(12)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// The saved sign-ins (Termius's keychain): a user with a key, a password, or both.
private struct CredentialsSection: View {
    @Environment(AppModel.self) private var model
    let edit: (ServerCredential) -> Void

    var body: some View {
        SettingsSection(title: "Credentials", footer: "Create a sign-in once and pick it for every server that uses it. Passwords stay in this Mac's Keychain; keys stay in ~/.ssh.") {
            ForEach(Array(model.serverCredentials.enumerated()), id: \.element.id) { index, credential in
                SettingsRow(title: credential.name, detail: detail(for: credential), divider: index > 0) {
                    Button("Edit…") { edit(credential) }
                }
            }
            Button {
                edit(ServerCredential(name: ""))
            } label: {
                Label("Add Credential…", systemImage: "plus")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textPrimary)
            .padding(14)
            .overlay(alignment: .top) {
                if !model.serverCredentials.isEmpty { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
            }
        }
    }

    /// "ubuntu · key · 2 servers".
    private func detail(for credential: ServerCredential) -> String {
        let count = model.servers.filter { $0.credentialID == credential.id }.count
        var parts = credential.summary.isEmpty ? [] : [credential.summary]
        if count > 0 { parts.append("\(count) server\(count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Adds or edits one credential: name, user, key (or .pem) and password.
struct CredentialEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ServerCredential
    @State private var keys = SSHKeys.list()
    /// Typed here; goes to the keychain on Save, never into a file.
    @State private var password = ""
    @State private var forgetPassword = false
    @State private var problem: String?
    private let isNew: Bool
    private let saved: ((ServerCredential) -> Void)?

    init(credential: ServerCredential, saved: ((ServerCredential) -> Void)? = nil) {
        _draft = State(initialValue: credential)
        isNew = credential.name.isEmpty
        self.saved = saved
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("acme uat"))
                    TextField("Username", text: Binding(get: { draft.user ?? "" }, set: { draft.user = $0.isEmpty ? nil : $0 }), prompt: Text("ubuntu, root…"))
                }

                Section {
                    Picker("Key", selection: $draft.keyPath) {
                        Text("None").tag(String?.none)
                        ForEach(keys) { key in
                            Text(key.comment.isEmpty ? key.name : "\(key.name) · \(key.comment)").tag(String?.some(key.privatePath))
                        }
                        if let path = draft.keyPath, !keys.contains(where: { $0.privatePath == path }) {
                            Text((path as NSString).abbreviatingWithTildeInPath).tag(String?.some(path))
                        }
                    }
                    Button("Choose Key File…", action: chooseKey)
                        .help("A .pem or other private key; it's copied to ~/.ssh/mountagent, readable only by you.")
                    HStack(spacing: 8) {
                        SecureField("Password", text: $password, prompt: Text(draft.hasPassword ? "Saved in Keychain" : "Optional"))
                        if draft.hasPassword {
                            Button("Forget") {
                                forgetPassword = true
                                draft.hasPassword = false
                                password = ""
                            }
                        }
                    }
                } header: {
                    Text("Sign In With")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !overridingServers.isEmpty {
                            Label("\(overridingServers.map(\.name).formatted(.list(type: .and))) \(overridingServers.count == 1 ? "has" : "have") a password of \(overridingServers.count == 1 ? "its" : "their") own, which is sent instead of this one. Forget it in the server's settings to use this password.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                        Text("A key, a password, or both. The password is kept in this Mac's Keychain only: not in Mountagent Desk's files, not synced, not in any repository, never shown to agents.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(Theme.Font.caption)
                }

                if let problem {
                    Text(problem).foregroundStyle(Theme.danger).font(Theme.Font.ui)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete Credential", role: .destructive) {
                        model.deleteCredential(draft)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 440)
    }

    /// Servers on this credential whose own saved password wins over its password.
    private var overridingServers: [Server] {
        guard draft.hasPassword || !password.isEmpty else { return [] }
        return model.servers.filter { $0.credentialID == draft.id && $0.passwordSaved }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        if !password.isEmpty {
            do {
                try ServerPasswords.save(password, account: draft.passwordAccount)
                draft.hasPassword = true
                forgetPassword = false
            } catch {
                problem = "Couldn't save the password in Keychain: \(error.localizedDescription)"
                return
            }
        }
        if forgetPassword { ServerPasswords.delete(account: draft.passwordAccount) }
        model.saveCredential(draft)
        saved?(draft)
        dismiss()
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key (.pem or similar)."
        panel.prompt = "Use Key"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            draft.keyPath = try ServerKeys.importKey(from: url)
            problem = nil
        } catch {
            problem = "Couldn't copy the key: \(error.localizedDescription)"
        }
    }
}

/// The user's own commands for the Servers panel's Commands menu.
private struct SnippetsSection: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var command = ""

    var body: some View {
        SettingsSection(title: "Your Commands", footer: "Shown under the built-in commands in the Servers panel. Picking one types it into the terminal; nothing runs until you press Return.") {
            ForEach(Array(model.serverSnippets.enumerated()), id: \.element.id) { index, snippet in
                SettingsRow(title: snippet.title, detail: snippet.command, divider: index > 0) {
                    Button(role: .destructive) {
                        model.saveSnippets(model.serverSnippets.filter { $0.id != snippet.id })
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 8) {
                TextField("Name", text: $title)
                    .frame(width: 150)
                TextField("Command", text: $command)
                    .font(Theme.Font.toolTarget)
                Button("Add") {
                    model.saveSnippets(model.serverSnippets + [ServerSnippet(title: title, command: command)])
                    title = ""
                    command = ""
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
            .overlay(alignment: .top) {
                if !model.serverSnippets.isEmpty { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
            }
        }
    }
}

/// Adds or edits one server: address, then a credential to sign in with, as in Termius.
struct ServerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Server
    @State private var testing = false
    @State private var testResult: SSHLogin.TestResult?
    @State private var newCredential: ServerCredential?
    /// Typed here; goes to the keychain on Save (or Test), never into a file.
    @State private var password = ""
    @State private var forgetPassword = false
    @State private var storedForTest = false
    @State private var problem: String?
    private let isNew: Bool

    init(server: Server) {
        _draft = State(initialValue: server)
        isNew = server.host.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Acme UAT"))
                    TextField("Host", text: $draft.host, prompt: Text("Host name, IP or a Host from ~/.ssh/config"))
                    TextField("Port", text: Binding(get: { draft.port.map(String.init) ?? "" }, set: { draft.port = Int($0) }), prompt: Text("22"))
                } header: {
                    Text("Server")
                } footer: {
                    Text("Put live, UAT or test in the name: a name with live or prod asks before connecting and shows its terminal in red.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Section {
                    TextField("Username", text: Binding(get: { draft.user ?? "" }, set: { draft.user = $0.isEmpty ? nil : $0 }),
                              prompt: Text(model.credential(draft.credentialID)?.user ?? "From the credential or SSH config"))
                    HStack(spacing: 8) {
                        SecureField("Password", text: $password, prompt: Text(passwordPrompt))
                        if draft.passwordSaved {
                            Button("Forget") {
                                forgetPassword = true
                                draft.passwordSaved = false
                                password = ""
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Picker("Credential", selection: $draft.credentialID) {
                            Text("None (SSH config / default key)").tag(UUID?.none)
                            ForEach(model.serverCredentials) { credential in
                                Text(credential.summary.isEmpty ? credential.name : "\(credential.name) · \(credential.summary)").tag(UUID?.some(credential.id))
                            }
                        }
                        Button("New…") { newCredential = ServerCredential(name: "") }
                    }
                    HStack(spacing: 8) {
                        Button("Test Connection", action: test)
                            .disabled(testing || draft.host.isEmpty)
                        if testing { ProgressView().controlSize(.small) }
                        switch testResult {
                        case .connected:
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).lineLimit(2)
                        case nil:
                            EmptyView()
                        }
                    }
                    .font(Theme.Font.ui)
                } header: {
                    Text("Credentials")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if draft.passwordSaved, model.credential(draft.credentialID)?.hasPassword == true {
                            Label("This server's password is sent, not the credential's. Forget it to use the credential's password.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warning)
                        }
                        Text("Type this server's password, or pick a saved credential (a key, a .pem or a shared password) — or both. Passwords are kept in this Mac's Keychain only, never in files or repositories, never shown to agents.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(Theme.Font.caption)
                }

                Section {
                    Toggle("Let agents read this server", isOn: $draft.aiReadAccess)
                    TextField("sudo for agents", text: Binding(
                        get: { draft.agentSudoUsers.joined(separator: ", ") },
                        set: { draft.agentSudoUsers = $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
                    ), prompt: Text("none"))
                    .disabled(!draft.aiReadAccess)
                    .help("Users agents may sudo -u to, such as postgres (root for plain sudo). Leave empty to refuse sudo: it lets a read reach files and databases this SSH user can't.")
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Off: agents can't reach this server at all. On: agents of the projects using it may run read-only commands (logs, status, SELECT queries) through \(ServerHelper.commandName); anything that changes the server is refused.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem {
                    Text(problem).foregroundStyle(Theme.danger).font(Theme.Font.ui).lineLimit(2)
                }
                if !isNew {
                    Button("Delete Server", role: .destructive) {
                        model.deleteServer(draft)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    // A password kept only to test a server that was never added goes again.
                    if storedForTest, model.server(draft.id) == nil { ServerPasswords.delete(account: draft.passwordAccount) }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespaces)
                    draft.host = draft.host.trimmingCharacters(in: .whitespaces)
                    if draft.name.isEmpty { draft.name = draft.host }
                    guard storePassword() else { return }
                    if forgetPassword { ServerPasswords.delete(account: draft.passwordAccount) }
                    model.saveServer(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
        .sheet(item: $newCredential) { credential in
            CredentialEditor(credential: credential) { draft.credentialID = $0.id }
        }
    }

    private var passwordPrompt: String {
        if draft.passwordSaved { return "Saved in Keychain" }
        if model.credential(draft.credentialID)?.hasPassword == true { return "From the credential" }
        return "Optional"
    }

    /// Moves a typed password into the keychain; false (with the reason shown) if that failed.
    private func storePassword() -> Bool {
        guard !password.isEmpty else { return true }
        do {
            try ServerPasswords.save(password, account: draft.passwordAccount)
            draft.passwordSaved = true
            forgetPassword = false
            password = ""
            problem = nil
            return true
        } catch {
            problem = "Couldn't save the password in Keychain: \(error.localizedDescription)"
            return false
        }
    }

    private func test() {
        if !password.isEmpty {
            storedForTest = true
            guard storePassword() else { return }
        }
        testing = true
        testResult = nil
        let login = model.login(for: draft)
        let askpass = model.askpass
        Task.detached {
            let result = login.testConnection(askpass: askpass)
            await MainActor.run {
                testResult = result
                testing = false
            }
        }
    }
}

/// Picks hosts from `~/.ssh/config` to add as servers.
private struct SSHImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SSHConfigImport.Entry] = []
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if entries.isEmpty {
                        Text("No new hosts in ~/.ssh/config.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(entries) { entry in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(entry.alias) },
                            set: { if $0 { chosen.insert(entry.alias) } else { chosen.remove(entry.alias) } }
                        )) {
                            HStack(spacing: 8) {
                                Circle().fill(entry.server.environment.tint).frame(width: 7, height: 7)
                                Text(entry.alias)
                                Text(entry.summary)
                                    .font(Theme.Font.toolTarget)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Hosts in ~/.ssh/config")
                } footer: {
                    Text("Each host keeps its alias, so the config's user, key and other settings still apply. Rename them with Edit afterwards.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(chosen.count)") {
                    for entry in entries where chosen.contains(entry.alias) {
                        model.saveServer(entry.server)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540, height: 520)
        .task {
            let known = Set(model.servers.map(\.host))
            entries = await Task.detached { SSHConfigImport.entries() }.value.filter { !known.contains($0.alias) }
        }
    }
}

// MARK: - Right panel

/// The project's servers, with SSH terminals in tabs, ready-made commands and "send to chat".
struct ServersPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @AppStorage(TerminalTheme.key) private var theme = TerminalTheme.app
    let project: Project
    @State private var confirmLive: Server?

    private var terminals: ServerTerminals { .shared }

    var body: some View {
        let linked = model.servers(of: project)
        let tabs = terminals.tabs(of: project.id)
        let selected = tabs.first { $0.id == terminals.selected[project.id] } ?? tabs.last
        VStack(spacing: 0) {
            listHeader
            if linked.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(linked) { server in
                            row(server)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: tabs.isEmpty ? .infinity : min(CGFloat(linked.count) * 40 + 8, 168))
            }
            if let selected, let server = model.server(selected.serverID) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                tabStrip(tabs, selected: selected)
                terminal(selected, server: server)
            } else if !linked.isEmpty {
                Spacer(minLength: 0)
            }
        }
        .alert(
            "Connect to \(confirmLive?.name ?? "")?",
            isPresented: Binding(get: { confirmLive != nil }, set: { if !$0 { confirmLive = nil } }),
            presenting: confirmLive
        ) { server in
            Button("Connect") { terminals.open(model.login(for: server), in: project.id) }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("\(model.login(for: server).destination) looks like a live server. What you run there affects real users.")
        }
    }

    private var listHeader: some View {
        HStack(spacing: 4) {
            Text("Servers of \(project.name)")
                .lineLimit(1)
            Spacer()
            Menu {
                ForEach(model.servers) { server in
                    Toggle(isOn: Binding(
                        get: { project.serverIDs.contains(server.id) },
                        set: { model.setServer(server.id, linked: $0, to: project) }
                    )) {
                        Text(server.name)
                    }
                }
                if !model.servers.isEmpty { Divider() }
                Button("Manage Servers…") { showSettings() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .chipMenu()
            .help("Link servers to this project")
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.textTertiary)
        .padding(.leading, 15)
        .padding(.trailing, 8)
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
            Text(model.servers.isEmpty
                 ? "Add your live, UAT and test servers, then open SSH terminals to them here."
                 : "Link this project's servers with the ••• menu above.")
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if model.servers.isEmpty {
                Button("Add Servers…") { showSettings() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ server: Server) -> some View {
        HStack(spacing: 8) {
            Circle().fill(server.environment.tint).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(Theme.Font.uiMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(model.login(for: server).destination)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Toggle(isOn: Binding(get: { server.aiReadAccess }, set: { model.setReadAccess($0, for: server.id) })) {
                Text("Agents read")
                    .font(Theme.Font.caption)
                    .foregroundStyle(server.aiReadAccess ? Theme.warning : Theme.textTertiary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(server.aiReadAccess
                  ? "Agents may run read-only commands here. Turn off to keep them out."
                  : "Agents can't reach this server. Turn on to let them run read-only commands.")
            ChromeButton(symbol: "apple.terminal", help: "Open an SSH terminal") { connect(server) }
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { connect(server) }
        .hoverHighlight()
    }

    private func tabStrip(_ tabs: [ServerTerminals.Tab], selected: ServerTerminals.Tab) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    if let server = model.server(tab.serverID) {
                        let isSelected = tab.id == selected.id
                        HStack(spacing: 5) {
                            Circle()
                                .fill(tab.connected ? server.environment.tint : Theme.textTertiary)
                                .frame(width: 6, height: 6)
                            Text(server.name)
                                .font(Theme.Font.ui)
                                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                            Button {
                                terminals.close(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                            .help("Close (ends the SSH session)")
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 4)
                        .frame(height: 24)
                        .background(isSelected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { terminals.selected[project.id] = tab.id }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 32)
    }

    private func terminal(_ tab: ServerTerminals.Tab, server: Server) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if server.environment == .live {
                    Label("LIVE", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Theme.danger)
                }
                Text(model.login(for: server).destination)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                CommandHistoryButton(server: server, tabID: tab.id)
                commandsMenu(tab)
                sendMenu(tab, server: server)
                ChromeButton(symbol: "arrow.clockwise", help: "Reconnect") {
                    terminals.reconnect(tab.id, to: model.login(for: server))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)
            ServerTerminalHost(tabID: tab.id, dark: colorScheme == .dark, theme: theme)
                .id("\(tab.id)-\(tab.generation)")
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .background(theme.background(dark: colorScheme == .dark))
                .overlay {
                    if server.environment == .live {
                        Rectangle().strokeBorder(Theme.danger.opacity(0.7), lineWidth: 2).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !tab.connected {
                        HStack(spacing: 8) {
                            Text("Disconnected")
                                .font(Theme.Font.ui)
                                .foregroundStyle(Theme.textSecondary)
                            Button("Reconnect") { terminals.reconnect(tab.id, to: model.login(for: server)) }
                                .controlSize(.small)
                        }
                        .padding(8)
                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
                        .padding(10)
                    }
                }
        }
        .background(Theme.codeBackground)
    }

    private func commandsMenu(_ tab: ServerTerminals.Tab) -> some View {
        Menu {
            Section("Common") {
                ForEach(ServerSnippet.common) { snippet in
                    Button(snippet.title) { terminals.type(snippet.command, in: tab.id) }
                }
            }
            if !model.serverSnippets.isEmpty {
                Section("Yours") {
                    ForEach(model.serverSnippets) { snippet in
                        Button(snippet.title) { terminals.type(snippet.command, in: tab.id) }
                    }
                }
            }
            Divider()
            Button("Edit Your Commands…") { showSettings() }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .chipMenu()
        .help("Type a command (runs when you press Return)")
    }

    private func sendMenu(_ tab: ServerTerminals.Tab, server: Server) -> some View {
        Menu {
            Button("Selected Text") {
                if let text = terminals.selection(in: tab.id) { sendToChat(text, from: server) }
            }
            Button("Last 50 Lines") { sendToChat(terminals.recentOutput(in: tab.id, lines: 50), from: server) }
            Button("Last 200 Lines") { sendToChat(terminals.recentOutput(in: tab.id, lines: 200), from: server) }
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .chipMenu()
        .help("Send terminal output to the chat")
    }

    private func connect(_ server: Server) {
        if server.environment == .live {
            confirmLive = server
        } else {
            terminals.open(model.login(for: server), in: project.id)
        }
    }

    private func sendToChat(_ text: String, from server: Server) {
        guard !text.isEmpty else { return }
        let block = "Output from \(server.name):\n```\n\(text)\n```\n"
        NotificationCenter.default.post(name: .insertIntoComposer, object: nil, userInfo: ["text": block])
    }

    private func showSettings() {
        SettingsPane.show(.servers)
        openSettings()
    }
}

// MARK: - Command history

/// The server's command history, as in Termius: pinned commands on top, then newest first.
/// Each row pastes its command into the terminal (never runs it) or pins it.
private struct CommandHistoryButton: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let tabID: UUID
    @State private var showing = false
    @State private var search = ""
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .buttonStyle(.plain)
        .help("Command history")
        .popover(isPresented: $showing, arrowEdge: .bottom) { list }
        #if DEBUG
        // `MOUNTAGENT_SHOW_HISTORY` opens it, for snapshots.
        .task {
            guard ProcessInfo.processInfo.environment["MOUNTAGENT_SHOW_HISTORY"] != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            showing = true
        }
        #endif
    }

    private var list: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = model.history(of: server.id).ordered.filter { query.isEmpty || $0.command.lowercased().contains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Load from Server", action: load)
                        .controlSize(.small)
                        .help("Add the server's own shell history (~/.bash_history and ~/.zsh_history), including commands run from other apps")
                }
            }
            .font(Theme.Font.ui)
            .padding(10)
            if let importMessage {
                Text(importMessage)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    if entries.isEmpty {
                        Text(query.isEmpty ? "Commands you run in this server's terminal appear here." : "No command matches.")
                            .font(Theme.Font.ui)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(12)
                    }
                }
                .padding(4)
            }
            // A popover gives a scroll view no height of its own; size it to the rows.
            .frame(height: min(max(CGFloat(entries.count) * 30 + 8, 60), 400))
        }
        .frame(width: 400)
    }

    private func row(_ entry: ServerCommandHistory.Entry) -> some View {
        HStack(spacing: 6) {
            Text(entry.command)
                .font(Theme.Font.toolTarget)
                .foregroundStyle(entry.pinned ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(entry.command)
            Spacer(minLength: 4)
            iconButton(entry.pinned ? "pin.fill" : "pin", tint: entry.pinned ? Theme.warning : Theme.textTertiary,
                       help: entry.pinned ? "Unpin" : "Pin to the top") {
                model.updateHistory(of: server.id) { $0.togglePin(entry.command) }
            }
            iconButton("doc.on.clipboard", tint: Theme.accent, help: "Paste into the terminal (press Return to run it)") {
                ServerTerminals.shared.type(entry.command, in: tabID)
                showing = false
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .hoverHighlight()
        .contextMenu {
            Button("Copy") { Clipboard.copy(entry.command) }
            Button("Save as Command…") {
                let title = String(entry.command.prefix(40))
                model.saveSnippets(model.serverSnippets + [ServerSnippet(title: title, command: entry.command)])
            }
            Divider()
            Button("Remove from History", role: .destructive) {
                model.updateHistory(of: server.id) { $0.remove(entry.command) }
            }
        }
    }

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func load() {
        importing = true
        importMessage = nil
        Task {
            switch await model.importShellHistory(of: server) {
            case .success(let count):
                importMessage = count == 0 ? "The server has no shell history yet." : "Loaded \(count) commands from the server."
            case .failure(let error):
                importMessage = "Couldn't read the server's history: \(error.localizedDescription)"
            }
            importing = false
        }
    }
}
