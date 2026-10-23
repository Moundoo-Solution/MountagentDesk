import MountagentDeskKit
import SwiftUI

/// Next to the branch: the branch's pull request, or a button that opens one.
struct PullRequestChip: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    let project: Project

    var body: some View {
        let branch = model.branchName(of: session, project: project)
        Group {
            if let branch, !PullRequestDraft.mainBranches.contains(branch) {
                if let request = model.pullRequests[session.id] {
                    Button { NSWorkspace.shared.open(request.url) } label: {
                        chip("arrow.triangle.pull", "#\(request.number)", tint: tint(request))
                    }
                    .buttonStyle(.plain)
                    .help("\(request.isDraft ? "Draft pull request" : "Pull request") #\(request.number), \(request.state.lowercased()) — open on GitHub")
                } else {
                    Button { model.pullRequestSessionID = session.id } label: {
                        chip("arrow.triangle.pull", "Create PR", tint: Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Push \(branch) and open a pull request on GitHub")
                }
            }
        }
        .task(id: branch) { model.refreshPullRequest(for: session.id) }
    }

    private func chip(_ symbol: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(tint.opacity(0.12), in: Capsule())
        .contentShape(Capsule())
    }

    private func tint(_ request: GitHubCLI.PullRequest) -> Color {
        switch request.state {
        case "MERGED": Color(light: 0x8250DF, dark: 0xA371F7)
        case "CLOSED": Theme.danger
        default: request.isDraft ? Theme.textSecondary : Theme.success
        }
    }
}

/// Title, description and base for a new pull request, filled in from the session and the
/// branch's commits; Create pushes the branch and opens it with `gh`.
struct PullRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: UUID
    @State private var title = ""
    @State private var bodyText = ""
    @State private var base = "main"
    @State private var draft = false
    @State private var working = false
    @State private var problem: String?
    @State private var loaded = false

    private var session: ChatSession? { model.sessions[sessionID] }
    private var project: Project? { model.project(session?.projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Into", text: $base)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Draft", isOn: $draft)
                    TextEditor(text: $bodyText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160)
                } header: {
                    Text("Pull Request")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if GitHubCLI.locate() == nil {
                            Text("Needs the GitHub CLI (gh), signed in: Settings → Git → Connect with GitHub.")
                                .foregroundStyle(Theme.warning)
                        } else if let branch = session.flatMap({ s in project.flatMap { model.branchName(of: s, project: $0) } }) {
                            Text("Pushes \(branch) to origin, then opens the pull request with gh\(model.gitAccount(project?.gitAccountID)?.githubLogin.map { " as \($0)" } ?? "").")
                        }
                        if let problem {
                            Text(problem).foregroundStyle(Theme.danger).textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(working)

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Pull Request") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || title.trimmingCharacters(in: .whitespaces).isEmpty || base.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        guard !loaded, let session, let project, let branch = model.branchName(of: session, project: project) else { return }
        loaded = true
        title = PullRequestDraft.title(session: session.title, branch: branch)
        let root = model.workRoot(of: session, project: project)
        let summary = session.items.last { $0.kind == .assistant }?.text
        let login = model.gitAccount(project.gitAccountID)?.githubLogin
        let (defaultBase, commits) = await Task.detached { () -> (String?, [String]) in
            let base = GitHubCLI.defaultBranch(in: root, token: login.flatMap(GitHubCLI.token(for:)))
            return (base, GitClient(root: root).subjects(since: base ?? "main"))
        }.value
        if let defaultBase { base = defaultBase }
        if bodyText.isEmpty { bodyText = PullRequestDraft.body(summary: summary, commits: commits) }
    }

    private func create() {
        working = true
        problem = nil
        Task {
            do {
                try await model.createPullRequest(for: sessionID, title: title.trimmingCharacters(in: .whitespaces), body: bodyText,
                                                  base: base.trimmingCharacters(in: .whitespaces), draft: draft)
                dismiss()
            } catch {
                problem = (error as? GitClient.Failure)?.message ?? error.localizedDescription
            }
            working = false
        }
    }
}
