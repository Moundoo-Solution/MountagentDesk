import MountagentDeskKit
import SwiftUI

/// One account in Settings → Git: avatar, identity, key and the projects using it.
struct GitAccountRow: View {
    let account: GitAccount
    let projects: [Project]
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GitAccountAvatar(account: account, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.label.isEmpty ? account.name : account.label)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(account.name) <\(account.email)>")
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textSecondary)
                if let login = account.githubLogin {
                    Label("github.com/\(login)", systemImage: "checkmark.seal")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.success)
                }
                Label(account.sshKeyPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Default SSH setup", systemImage: "key")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
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

/// Adds or edits one account: identity, SSH key (pick, or generate and add to GitHub),
/// and a connection test.
struct GitAccountEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GitAccount
    @State private var keys = SSHKeys.list()
    @State private var testing = false
    @State private var testResult: SSHKeys.TestResult?
    @State private var problem: String?
    @State private var githubTask: AppModel.SetupTask?
    @State private var githubAccounts: [String] = []
    @State private var accountsBeforeSignIn: [String] = []
    @State private var connecting = false
    @State private var keyStatus: String?
    private let isNew: Bool

    init(account: GitAccount) {
        _draft = State(initialValue: account)
        isNew = account.name.isEmpty && account.email.isEmpty
    }

    private var selectedKey: SSHKeys.Key? {
        keys.first { $0.privatePath == draft.sshKeyPath }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                githubSection

                Section("Account") {
                    TextField("Label", text: $draft.label, prompt: Text("Work, Personal…"))
                    TextField("Name", text: $draft.name, prompt: Text("Name shown on commits"))
                    TextField("Email", text: $draft.email, prompt: Text("Email on commits (verified on GitHub)"))
                }

                Section {
                    Picker("SSH key", selection: $draft.sshKeyPath) {
                        Text("Default SSH setup").tag(String?.none)
                        ForEach(keys) { key in
                            Text(key.comment.isEmpty ? key.name : "\(key.name) · \(key.comment)").tag(String?.some(key.privatePath))
                        }
                        if let path = draft.sshKeyPath, selectedKey == nil {
                            Text((path as NSString).abbreviatingWithTildeInPath).tag(String?.some(path))
                        }
                    }
                    HStack {
                        Button("Generate New Key") { generateKey() }
                            .disabled(draft.email.isEmpty)
                        if let key = selectedKey {
                            Button("Copy Public Key") {
                                Clipboard.copy(key.publicKey)
                            }
                            Button("Add to GitHub…") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/settings/ssh/new")!)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Test Connection") { test() }
                            .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        switch testResult {
                        case .authenticated(let username):
                            Label("GitHub signs this key in as \(username)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(Theme.success)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.circle.fill")
                                .foregroundStyle(Theme.danger)
                                .lineLimit(2)
                        case nil:
                            EmptyView()
                        }
                    }
                    .font(Theme.Font.ui)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Connect with GitHub sets this up for you. To do it by hand: each GitHub account needs its own key; generate one (no passphrase, so agents can push), copy the public key and add it under that account's GitHub → Settings → SSH keys.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                if let problem {
                    Text(problem).foregroundStyle(Theme.danger).font(Theme.Font.ui)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete Account", role: .destructive) {
                        model.deleteGitAccount(draft)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if draft.label.trimmingCharacters(in: .whitespaces).isEmpty { draft.label = draft.name }
                    model.saveGitAccount(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || !draft.email.contains("@"))
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .sheet(item: $githubTask) { task in
            SetupSheet(task: task) {
                githubTask = nil
                finishSignIn()
            }
        }
        .task { githubAccounts = await Task.detached { GitHubCLI.accounts() }.value }
    }

    // MARK: GitHub

    private var githubSection: some View {
        Section {
            if let login = draft.githubLogin {
                HStack(spacing: 10) {
                    GitAccountAvatar(account: draft, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name.isEmpty ? login : draft.name)
                            .fontWeight(.medium)
                        Label("github.com/\(login)", systemImage: "checkmark.seal.fill")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.success)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(draft.githubLogin == nil ? "Connect with GitHub…" : "Connect a Different Account…") { signIn() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(connecting)
                let others = githubAccounts.filter { $0 != draft.githubLogin }
                if !others.isEmpty {
                    Menu("Use Signed-In Account") {
                        ForEach(others, id: \.self) { login in
                            Button {
                                link(login)
                            } label: {
                                Label(login, systemImage: "person.crop.circle")
                            }
                        }
                    }
                    .fixedSize()
                }
                if connecting { ProgressView().controlSize(.small) }
            }
            if let keyStatus {
                Text(keyStatus)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        } header: {
            Text("GitHub")
        } footer: {
            Text("Signs in through your browser with GitHub's own CLI (installed with Homebrew if needed), then fills in the name and verified email, creates an SSH key for this account and adds it to GitHub. Several accounts can be signed in at once.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func signIn() {
        accountsBeforeSignIn = githubAccounts
        let command: String
        if let gh = GitHubCLI.locate() {
            command = GitHubCLI.loginCommand(gh: Shell.quote(gh.path))
        } else if let install = GitHubCLI.installCommand, let brew = ExecutableLocator.find("brew") {
            let gh = brew.deletingLastPathComponent().appendingPathComponent("gh").path
            command = install + " && " + GitHubCLI.loginCommand(gh: Shell.quote(gh))
        } else {
            problem = "Install GitHub CLI from cli.github.com, then try again."
            NSWorkspace.shared.open(URL(string: "https://cli.github.com")!)
            return
        }
        githubTask = AppModel.SetupTask(kind: nil, title: "Connect with GitHub", command: command, host: .settings, symbolName: "person.badge.key")
    }

    /// After the browser sign-in: link whichever account just appeared.
    private func finishSignIn() {
        Task {
            let accounts = await Task.detached { GitHubCLI.accounts() }.value
            githubAccounts = accounts
            let added = accounts.filter { !accountsBeforeSignIn.contains($0) }
            if let login = added.first ?? (accounts.count == 1 ? accounts.first : nil) {
                link(login)
            } else if accounts.isEmpty {
                problem = "GitHub sign-in didn't finish. Try again."
            }
        }
    }

    /// Fills the account from GitHub, makes sure it has its own key, and adds the key there.
    private func link(_ login: String) {
        connecting = true
        problem = nil
        keyStatus = "Reading \(login)'s profile…"
        Task {
            let profile = await Task.detached { GitHubCLI.profile(of: login) }.value
            draft.githubLogin = login
            if draft.label.trimmingCharacters(in: .whitespaces).isEmpty || draft.label == draft.name { draft.label = login }
            if let name = profile?.name, !name.isEmpty { draft.name = name } else if draft.name.isEmpty { draft.name = login }
            if let email = profile?.email { draft.email = email }

            // Reuse this account's key when it has one; a key shared with another account
            // would be rejected by GitHub.
            keys = SSHKeys.list()
            let keyName = "id_ed25519_\(login.lowercased())"
            if let existing = keys.first(where: { $0.name == keyName }) {
                draft.sshKeyPath = existing.privatePath
            } else if draft.sshKeyPath == nil || keys.first(where: { $0.privatePath == draft.sshKeyPath }) == nil {
                if let key = try? SSHKeys.generate(named: keyName, comment: draft.email) {
                    keys = SSHKeys.list()
                    draft.sshKeyPath = key.privatePath
                }
            }

            if let key = selectedKey {
                keyStatus = "Adding the SSH key to GitHub…"
                let title = "Mountagent Desk · \(Host.current().localizedName ?? "Mac")"
                let upload = await Task.detached { GitHubCLI.uploadKey(publicKey: key.publicKey, title: title, for: login) }.value
                switch upload {
                case .added: keyStatus = "Added \(key.name) to github.com/\(login)."
                case .alreadyThere: keyStatus = "\(key.name) is already on github.com/\(login)."
                case .failed(let message): keyStatus = message
                }
            } else {
                keyStatus = nil
            }
            connecting = false
            test()
        }
    }

    private func generateKey() {
        let base = (draft.label.isEmpty ? draft.name : draft.label).lowercased()
        do {
            let key = try SSHKeys.generate(named: "id_ed25519_\(base)", comment: draft.email)
            keys = SSHKeys.list()
            draft.sshKeyPath = key.privatePath
            problem = nil
        } catch {
            problem = "Couldn't create the key (one with that name may already exist in ~/.ssh)."
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let key = draft.sshKeyPath
        Task.detached {
            let result = SSHKeys.testGitHub(keyPath: key)
            await MainActor.run {
                testResult = result
                testing = false
            }
        }
    }
}

/// A git account's face: the GitHub avatar when the account is connected, otherwise its
/// initials on a color picked from the email, so accounts are easy to tell apart.
struct GitAccountAvatar: View {
    let account: GitAccount?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let login = account?.githubLogin,
               let url = URL(string: "https://github.com/\(login).png?size=\(Int(size * 3))") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline))
        .help(account.map { "\($0.label) · \($0.email)" } ?? "Global git config")
    }

    private var initials: some View {
        let source = account.map { $0.label.isEmpty ? $0.name : $0.label } ?? "?"
        let letters = source.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return ZStack {
            Circle().fill(color.opacity(0.22))
            Text(letters.isEmpty ? "?" : letters)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        guard let email = account?.email else { return Theme.textTertiary }
        return Theme.hue(for: email)
    }
}
