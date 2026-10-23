import MountagentDeskKit
import SwiftUI

/// Names a project and edits its folders. Changes apply on Save.
struct FoldersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Project
    /// Bumped after a remote changes, to re-read every repository's status.
    @State private var repoGeneration = 0

    init(project: Project) {
        _draft = State(initialValue: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Project name", text: $draft.name)

                Section {
                    ForEach(draft.allPaths, id: \.self) { path in
                        FolderRow(
                            path: path,
                            isPrimary: path == draft.path,
                            makePrimary: { draft.makePrimary(path) },
                            remove: { draft.additionalPaths.removeAll { $0 == path } }
                        )
                    }
                    Button {
                        let urls = AppModel.chooseFolders(prompt: "Add", message: "Add folders the agents may read and edit.", in: draft.url.deletingLastPathComponent())
                        draft.addFolders(urls.map(\.path))
                    } label: {
                        Label("Add Folders…", systemImage: "plus")
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Agents run in the main folder, which also holds the rules and skills you edit in Rules & Skills. The other folders are passed with --add-dir, so agents can read and edit them too. Changing the main folder starts each agent on a fresh CLI session; the conversation is handed over.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                    GitAccountAvatar(account: model.gitAccount(draft.gitAccountID), size: 24)
                    Picker("Git account", selection: $draft.gitAccountID) {
                        Text("Global git config").tag(UUID?.none)
                        ForEach(model.gitAccounts) { account in
                            Text("\(account.label) · \(account.email)").tag(UUID?.some(account.id))
                        }
                    }
                    }
                    ForEach(draft.allPaths, id: \.self) { path in
                        RepositoryStatus(path: path, generation: repoGeneration) { repoGeneration += 1 }
                    }
                } header: {
                    Text("Git")
                } footer: {
                    Text("Saving writes the account's name, email and SSH key into each repository's .git/config. Manage accounts in Settings → Git.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if model.servers.isEmpty {
                        Text("No servers yet. Add them in Settings → Servers.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.servers) { server in
                        Toggle(isOn: Binding(
                            get: { draft.serverIDs.contains(server.id) },
                            set: { linked in
                                draft.serverIDs.removeAll { $0 == server.id }
                                if linked { draft.serverIDs.append(server.id) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                Circle().fill(server.environment.tint).frame(width: 7, height: 7)
                                Text(server.name)
                                Text(model.login(for: server).destination)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Servers")
                } footer: {
                    Text("Linked servers open in the right panel's Servers. Agents in this project can't reach them, except read-only on servers where you turn on agent access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Also load rules from the other folders", isOn: $draft.loadsAdditionalRules)
                        .disabled(draft.additionalPaths.isEmpty)
                } footer: {
                    Text("Claude Code reads their CLAUDE.md. Cursor doesn't read rules outside its workspace, so Mountagent Desk sends their AGENTS.md (or CLAUDE.md) with the first message of each new Cursor session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if draft.name.isEmpty { draft.name = draft.url.lastPathComponent }
                    let accountChanged = draft.gitAccountID != model.project(draft.id)?.gitAccountID
                    model.updateProject(draft)
                    if accountChanged { model.applyGitAccount(draft.gitAccountID, to: draft) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 640)
    }
}

private struct FolderRow: View {
    let path: String
    let isPrimary: Bool
    let makePrimary: () -> Void
    let remove: () -> Void

    private var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: exists ? (isPrimary ? "folder.fill" : "folder") : "exclamationmark.triangle.fill")
                .foregroundStyle(exists ? (isPrimary ? Color.accentColor : .secondary) : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((path as NSString).lastPathComponent).fontWeight(isPrimary ? .semibold : .regular)
                    if isPrimary {
                        Text("Main")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(exists ? (path as NSString).abbreviatingWithTildeInPath : "Missing: \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !isPrimary {
                Button("Make Main", action: makePrimary)
                    .disabled(!exists)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from project (the folder itself is kept)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// One folder's git state: who it commits as, and whether its remote can use SSH keys.
private struct RepositoryStatus: View {
    @Environment(AppModel.self) private var model
    let path: String
    let generation: Int
    let changed: () -> Void
    @State private var identity: GitIdentity?
    @State private var isRepository = true

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Whose name the repository commits under right now, matched by email.
            GitAccountAvatar(account: model.gitAccounts.first { $0.email == identity?.email }, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text((path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                if !isRepository {
                    Text("Not a git repository").font(.caption).foregroundStyle(.secondary)
                } else if let identity {
                    Text("\(identity.name ?? "?") <\(identity.email ?? "?")>\(identity.isLocal ? "" : " · global")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let remote = identity.remoteURL {
                        Text(remote)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer()
            if let identity, identity.remoteIsHTTPS {
                Button("Use SSH") {
                    let root = URL(fileURLWithPath: path)
                    Task {
                        _ = await Task.detached { try? GitRepository(root: root).switchRemoteToSSH() }.value
                        changed()
                    }
                }
                .help("HTTPS remotes sign in through the keychain, which remembers one GitHub account. SSH uses the account's key.")
            }
        }
        .task(id: generation) {
            let root = URL(fileURLWithPath: path)
            let result = await Task.detached { () -> (Bool, GitIdentity?) in
                let repository = GitRepository(root: root)
                guard repository.isRepository else { return (false, nil) }
                return (true, repository.identity())
            }.value
            isRepository = result.0
            identity = result.1
        }
    }
}
