import MountagentDeskKit
import SwiftUI

// MARK: - Model

/// One repository as the Git window shows it: status, branches, stashes, the commit being
/// written, and the operation in flight.
@MainActor
@Observable
final class GitRepoModel {
    enum Tab: String { case changes, history }

    var root: String {
        didSet { if root != oldValue { reset() } }
    }
    var tab: Tab = .changes
    private(set) var status: GitClient.Status?
    private(set) var branches: [GitClient.Branch] = []
    private(set) var stashes: [GitClient.Stash] = []
    /// Files left out of the next commit (everything else is included, as in GitHub Desktop).
    var excluded: Set<String> = []
    var selectedFile: String?
    var summary = ""
    var details = ""
    /// The operation running now ("Pushing origin…").
    private(set) var busy: String?
    var error: String?

    /// The remote's web page, for links to pull requests.
    private(set) var webURL: URL?
    private var webURLRoot: String?

    var historyBranch: String?
    /// Committers whose commits History shows (emails); empty shows everyone's.
    var authorFilter: Set<String> = []
    /// Who committed on the history branch, for the filter.
    private(set) var authors: [GitLog.Author] = []
    private(set) var history: [GitLog.Commit] = []
    var selectedCommit: GitLog.Commit?
    /// Commits picked with ⌘- or ⇧-click, by SHA. With one or none, `selectedCommit` is the selection.
    private(set) var selectedSHAs: Set<String> = []
    private var anchorSHA: String?
    /// The branch tip saved before the last squash, while it can still be undone.
    private(set) var squashBackup: String?

    init(root: String) {
        self.root = root
    }

    var client: GitClient { GitClient(root: URL(fileURLWithPath: root)) }
    var files: [GitClient.FileStatus] { status?.files ?? [] }
    var included: [GitClient.FileStatus] { files.filter { !excluded.contains($0.path) } }

    private func reset() {
        status = nil
        excluded = []
        selectedFile = nil
        selectedCommit = nil
        selectedSHAs = []
        anchorSHA = nil
        historyBranch = nil
        authorFilter = []
        authors = []
        history = []
    }

    /// `polling`: the every-few-seconds look, which skips the author list (a shortlog over
    /// thousands of commits) and leaves unchanged values alone, so the lists don't redraw.
    func refresh(polling: Bool = false) async {
        let client = client
        let branchFilter = historyBranch ?? "HEAD"
        let authorEmails = authorFilter.sorted()
        let (status, branches, stashes, history, backup, authors) = await Task.detached {
            let status = client.status()
            return (status, client.branches(), client.stashes(), GitLog.commits(in: client.root, branch: branchFilter, limit: 300, authors: authorEmails),
                    status?.branch.flatMap(client.squashBackup(for:)), polling ? nil : GitLog.authors(in: client.root, branch: branchFilter))
        }.value
        if let authors, self.authors != authors { self.authors = authors }
        squashBackup = backup
        if webURLRoot != root {
            let url = URL(fileURLWithPath: root)
            webURL = await Task.detached { GitRepository(root: url).identity().remoteURL.flatMap(GitRepository.webURL(fromRemote:)) }.value
            webURLRoot = root
        }
        if self.status != status { self.status = status }
        if self.branches != branches { self.branches = branches }
        if self.stashes != stashes { self.stashes = stashes }
        if self.history != history { self.history = history }
        excluded = excluded.filter { path in status?.files.contains { $0.path == path } ?? false }
        if let selectedFile, !(status?.files.contains { $0.path == selectedFile } ?? false) { self.selectedFile = nil }
        if selectedFile == nil { selectedFile = status?.files.first?.path }
        if let selected = selectedCommit, !history.contains(selected) { selectedCommit = nil }
        if selectedCommit == nil { selectedCommit = history.first }
        let shown = Set(history.map(\.sha))
        selectedSHAs = selectedSHAs.filter(shown.contains)
    }

    /// The ⌘/⇧-picked commits, newest first; empty unless there are two or more.
    var multiSelection: [GitLog.Commit] {
        selectedSHAs.count > 1 ? history.filter { selectedSHAs.contains($0.sha) } : []
    }

    /// History shows a branch other than the checked-out one (cherry-pick into, not revert).
    var viewsOtherBranch: Bool {
        historyBranch != nil && historyBranch != status?.branch
    }

    func isSelected(_ commit: GitLog.Commit) -> Bool {
        selectedSHAs.count > 1 ? selectedSHAs.contains(commit.sha) : selectedCommit == commit
    }

    /// A click on a commit, as in Finder: ⌘ toggles it, ⇧ selects the run from the last
    /// clicked one. Returns true for a plain click, which opens the commit.
    func click(_ commit: GitLog.Commit, modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift), let anchor = anchorSHA ?? selectedCommit?.sha,
           let from = history.firstIndex(where: { $0.sha == anchor }), let to = history.firstIndex(of: commit) {
            selectedSHAs = Set(history[min(from, to)...max(from, to)].map(\.sha))
            return false
        }
        if modifiers.contains(.command) {
            if selectedSHAs.isEmpty, let current = selectedCommit { selectedSHAs = [current.sha] }
            if selectedSHAs.contains(commit.sha) { selectedSHAs.remove(commit.sha) } else { selectedSHAs.insert(commit.sha) }
            anchorSHA = commit.sha
            if selectedSHAs.count == 1, let only = history.first(where: { selectedSHAs.contains($0.sha) }) { selectedCommit = only }
            return false
        }
        selectedSHAs = [commit.sha]
        anchorSHA = commit.sha
        selectedCommit = commit
        return true
    }

    func clearMultiSelection() {
        selectedSHAs = selectedCommit.map { [$0.sha] } ?? []
    }

    /// Runs a write, shows its failure, then refreshes.
    func perform(_ title: String, _ operation: @escaping @Sendable (GitClient) throws -> Void) async {
        guard busy == nil else { return }
        busy = title
        error = nil
        let client = client
        let failure = await Task.detached { () -> String? in
            do {
                try operation(client)
                return nil
            } catch let failure as GitClient.Failure {
                return failure.message
            } catch {
                return error.localizedDescription
            }
        }.value
        busy = nil
        error = failure
        await refresh()
    }

    /// Points `origin` at SSH after an HTTPS sign-in failure, then fetches to confirm it works.
    func switchRemoteToSSH() async {
        let root = URL(fileURLWithPath: root)
        let switched = await Task.detached { (try? GitRepository(root: root).switchRemoteToSSH()) != nil }.value
        guard switched else {
            error = "Couldn't switch origin to SSH. Change it in Folders & Name."
            return
        }
        await perform("Fetching origin…") { try $0.fetch() }
    }
}

// MARK: - Window

/// The Git workspace in its own window (⇧⌘G), over every project's repositories.
struct GitWindow: View {
    @Environment(AppModel.self) private var model
    @State private var repo: GitRepoModel

    init(root: String, tab: GitRepoModel.Tab = .changes) {
        let repo = GitRepoModel(root: root)
        repo.tab = tab
        _repo = State(initialValue: repo)
    }

    var body: some View {
        GitWorkspace(repo: repo, repositories: nil, compact: false)
            .frame(minWidth: 960, minHeight: 560)
            .navigationTitle("Git · \((repo.root as NSString).lastPathComponent)")
    }
}

/// The Git tool in the side panel: the same workspace, laid out for the panel's width.
struct GitPanel: View {
    let project: Project
    @State private var repo: GitRepoModel

    init(project: Project) {
        self.project = project
        let repo = GitRepoModel(root: project.path)
        repo.tab = UserDefaults.standard.string(forKey: AppSettings.gitTabKey).flatMap(GitRepoModel.Tab.init(rawValue:)) ?? .changes
        _repo = State(initialValue: repo)
    }

    var body: some View {
        GeometryReader { geometry in
            GitWorkspace(repo: repo, repositories: project.allPaths, compact: geometry.size.width < 700)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: project.path) { repo.root = project.path }
        .onChange(of: repo.tab) { UserDefaults.standard.set(repo.tab.rawValue, forKey: AppSettings.gitTabKey) }
    }
}

// MARK: - Workspace

/// GitHub Desktop for the agents' repositories: repository and branch pickers, a sync
/// button, then Changes (pick files, commit) and History (inspect, cherry-pick, revert…).
/// Wide: list and detail side by side. Compact (side panel): the list, and a tap opens the
/// diff or commit in place with a back button.
struct GitWorkspace: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    /// Repositories offered in the picker; `nil` means every project's.
    let repositories: [String]?
    let compact: Bool
    @State private var confirmation: Confirmation?
    @State private var naming: Naming?
    @State private var squashing: GitClient.SquashPlan?
    /// Compact layout: the file or commit opened from the list.
    @State private var openedFile: String?
    @State private var openedCommit = false
    /// The detail column (diff, commit) in the wide layout; hidden, the list takes the full
    /// width and opens details in place, as in the compact layout.
    @AppStorage("gitShowsDetail") private var showsDetail = true

    private var stacked: Bool { compact || !showsDetail }

    /// Writes wait while an agent works in this repository.
    private var agentBusy: Bool { model.isRepositoryBusy(repo.root) }
    private var locked: Bool { agentBusy || repo.busy != nil }

    var body: some View {
        VStack(spacing: 0) {
            GitTopBar(repo: repo, repositories: repositories, compact: compact, showsDetail: compact ? nil : $showsDetail, locked: locked, confirm: { confirmation = $0 }, name: { naming = $0 })
            banners
            if stacked {
                compactBody
            } else {
                HSplitView {
                    sidebar
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 520)
                    detail
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
        .background(Theme.background)
        .task(id: "\(repo.root)|\(repo.historyBranch ?? "HEAD")|\(repo.authorFilter.sorted())|\(model.branches.revision(of: repo.root))") { await repo.refresh() }
        .task(id: repo.root) {
            // Working-tree edits don't touch .git, so look again every few seconds.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                // Only while the app is in use: git status on a large checkout is costly.
                if repo.busy == nil, NSApp.isActive { await repo.refresh(polling: true) }
            }
        }
        .onChange(of: repo.root) {
            openedFile = nil
            openedCommit = false
        }
        #if DEBUG
        .task { await debugSelection() }
        #endif
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { item in
            ForEach(item.actions.indices, id: \.self) { index in
                let action = item.actions[index]
                Button(action.title, role: action.destructive ? .destructive : nil) {
                    Task { await repo.perform(action.busyTitle, action.run) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
        .sheet(isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            if let naming { NewBranchSheet(repo: repo, naming: naming) }
        }
        .sheet(isPresented: Binding(get: { squashing != nil }, set: { if !$0 { squashing = nil } })) {
            if let squashing { SquashSheet(repo: repo, plan: squashing) }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if agentBusy {
            Banner(symbol: "hourglass", tint: Theme.warning, text: "An agent is working in this repository. Commits, checkouts and syncs wait until it finishes.")
        }
        if repo.squashBackup != nil, let branch = repo.status?.branch {
            let diverged = (repo.status?.ahead ?? 0) > 0 && (repo.status?.behind ?? 0) > 0
            Banner(symbol: "arrow.triangle.merge", tint: Theme.action,
                   text: diverged
                       ? "Squashed on \(branch). Origin still has the old commits: Sync is now Force Push, which replaces them. Pulling would bring them back."
                       : "Squashed on \(branch). You can undo it until you push.",
                   action: ("Undo Squash", {
                       Task { await repo.perform("Undoing squash…") { try $0.undoSquash(on: branch) } }
                   }),
                   dismiss: diverged ? nil : {
                       Task { await repo.perform("Keeping the squash…") { $0.dropSquashBackup(for: branch) } }
                   })
        }
        if let error = repo.error {
            if GitRepository.isHTTPSSignInFailure(error) {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.danger,
                       text: error + "\n\nThis remote uses HTTPS, which signs in with whatever GitHub account the keychain remembers, not this project's Git account. Switching origin to SSH uses the account's key instead.",
                       action: ("Use SSH", { Task { await repo.switchRemoteToSSH() } })) { repo.error = nil }
            } else {
                Banner(symbol: "exclamationmark.triangle.fill", tint: Theme.danger, text: error) { repo.error = nil }
            }
        }
        if let operation = repo.status?.inProgress {
            let conflicts = repo.status?.conflicted ?? []
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.warning)
                    Text("\(operation.title) in progress" + (conflicts.isEmpty ? " · conflicts resolved" : " · \(conflicts.count) conflicted file\(conflicts.count == 1 ? "" : "s")"))
                        .foregroundStyle(Theme.textPrimary)
                }
                if !compact { Spacer() }
                HStack(spacing: 8) {
                    if CursorApp.isInstalled, !conflicts.isEmpty {
                        Button(compact ? "Open in Cursor" : "Open Conflicts in Cursor") {
                            CursorApp.open(conflicts.map { URL(fileURLWithPath: repo.root).appendingPathComponent($0.path) })
                        }
                    }
                    Button("Abort", role: .destructive) {
                        Task { await repo.perform("Aborting…") { try $0.abort(operation) } }
                    }
                    Button("Continue") {
                        Task { await repo.perform("Continuing…") { try $0.continueOperation(operation) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
            }
            .font(Theme.Font.ui)
            .disabled(locked)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.10))
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("Changes", count: repo.files.count, tab: .changes)
            tabButton("History", count: nil, tab: .history)
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // MARK: Wide layout

    private var sidebar: some View {
        VStack(spacing: 0) {
            tabs
            switch repo.tab {
            case .changes:
                changesList
            case .history:
                CommitList(repo: repo, locked: locked, confirm: { confirmation = $0 }, name: { naming = $0 }, squash: startSquash) { repo.selectedCommit = $0 }
            }
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var changesList: some View {
        ChangesList(repo: repo, locked: locked, confirm: { confirmation = $0 }) { path in
            repo.selectedFile = path
            if stacked { openedFile = path }
        }
        if let stash = repo.stashes.first(where: { $0.message.contains("Mountagent Desk") }) {
            StashBar(repo: repo, stash: stash, locked: locked, confirm: { confirmation = $0 })
        }
        CommitBox(repo: repo, locked: locked)
    }

    private func tabButton(_ title: String, count: Int?, tab: GitRepoModel.Tab) -> some View {
        Button {
            repo.tab = tab
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Theme.action, in: Capsule())
                }
            }
            .font(.system(size: 12.5, weight: repo.tab == tab ? .semibold : .regular))
            .foregroundStyle(repo.tab == tab ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if repo.tab == tab { Rectangle().fill(Theme.action).frame(height: 2) }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch repo.tab {
        case .changes:
            if let path = repo.selectedFile, let file = repo.files.first(where: { $0.path == path }) {
                fileDiff(file)
            } else {
                PlaceholderPane(symbol: "checkmark.circle", title: "No local changes", text: repo.status.map { "\($0.branch ?? "Detached HEAD") is up to date with your last commit." } ?? "")
            }
        case .history:
            if repo.multiSelection.count > 1 {
                MultiCommitPane(repo: repo, locked: locked, squash: startSquash)
            } else if let commit = repo.selectedCommit {
                CommitDetailPane(commit: commit, root: repo.root, compact: false)
            } else {
                PlaceholderPane(symbol: "clock.arrow.circlepath", title: "Select a commit", text: "Its message, changed files and diff show here.")
            }
        }
    }

    private func fileDiff(_ file: GitClient.FileStatus) -> some View {
        FileDiffPane(title: file.path, load: { [client = repo.client] in client.diff(of: file) }, key: "\(file.path)|\(repo.status?.headSHA ?? "")|\(repo.files.hashValue)")
    }

    // MARK: Compact layout

    @ViewBuilder
    private var compactBody: some View {
        switch repo.tab {
        case .changes:
            if let path = openedFile, let file = repo.files.first(where: { $0.path == path }) {
                backBar(title: "Changes") { openedFile = nil }
                fileDiff(file)
            } else {
                tabs
                changesList
                    .background(Theme.sidebar)
            }
        case .history:
            if openedCommit, let commit = repo.selectedCommit {
                backBar(title: "History") { openedCommit = false }
                CommitDetailPane(commit: commit, root: repo.root, compact: compact)
            } else {
                tabs
                CommitList(repo: repo, locked: locked, confirm: { confirmation = $0 }, name: { naming = $0 }, squash: startSquash) { commit in
                    repo.selectedCommit = commit
                    openedCommit = true
                }
                .background(Theme.sidebar)
            }
        }
    }

    #if DEBUG
    /// `MOUNTAGENT_SELECT_COMMITS=1-3` selects those history rows (0 is newest);
    /// `MOUNTAGENT_OPEN_SQUASH` then opens the squash sheet; `MOUNTAGENT_HISTORY_AUTHORS=a@x,b@y`
    /// filters History to those committers. For snapshots.
    private func debugSelection() async {
        let environment = ProcessInfo.processInfo.environment
        if let emails = environment["MOUNTAGENT_HISTORY_AUTHORS"] {
            repo.authorFilter = Set(emails.split(separator: ",").map(String.init))
        }
        guard let spec = environment["MOUNTAGENT_SELECT_COMMITS"] else { return }
        let bounds = spec.split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2 else { return }
        try? await Task.sleep(for: .seconds(1.5))
        repo.tab = .history
        guard bounds.allSatisfy(repo.history.indices.contains) else { return }
        _ = repo.click(repo.history[bounds[0]], modifiers: [])
        _ = repo.click(repo.history[bounds[1]], modifiers: .shift)
        if environment["MOUNTAGENT_OPEN_SQUASH"] != nil { startSquash(repo.multiSelection) }
    }
    #endif

    /// Checks the selection off the main thread, then asks for the message.
    private func startSquash(_ commits: [GitLog.Commit]) {
        let client = repo.client
        Task {
            let result = await Task.detached { Result { try client.planSquash(commits) } }.value
            switch result {
            case .success(let plan): squashing = plan
            case .failure(let error): repo.error = (error as? GitClient.Failure)?.message ?? error.localizedDescription
            }
        }
    }

    private func backBar(title: String, back: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            ChromeButton(symbol: "chevron.left", help: "Back to \(title)", action: back)
            Text(title).font(Theme.Font.uiMedium).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Confirmations

struct Confirmation {
    struct Action {
        var title: String
        var busyTitle: String
        var destructive = false
        var run: @Sendable (GitClient) throws -> Void
    }

    var title: String
    var message: String
    var actions: [Action]
}

struct Naming {
    var title: String
    var message: String
    /// Start point; empty means the current HEAD.
    var start: String
    /// Offer a branch (local or remote) to start from; off when starting from a chosen commit.
    var choosesStart = false
}

/// Names a new branch and, from the branch picker, chooses the branch it starts from.
struct NewBranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repo: GitRepoModel
    let naming: Naming
    @State private var name = ""
    @State private var start: String
    @State private var search = ""

    init(repo: GitRepoModel, naming: Naming) {
        self.repo = repo
        self.naming = naming
        _start = State(initialValue: naming.choosesStart ? (repo.status?.branch ?? "") : naming.start)
    }

    private var current: String? { repo.status?.branch }
    private var branchName: String { name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-") }
    private var exists: Bool { repo.branches.contains { !$0.isRemote && $0.name == branchName } }

    private func filtered(remote: Bool) -> [GitClient.Branch] {
        repo.branches.filter { $0.isRemote == remote && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    private var note: String {
        if !naming.choosesStart { return naming.message }
        if start.isEmpty || start == current { return "Your uncommitted changes come along." }
        let remote = repo.branches.contains { $0.isRemote && $0.name == start }
        return (remote ? "Starts at \(start) without tracking it; Publish sets its own upstream. " : "")
            + "Uncommitted changes come along unless they conflict."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(naming.title).font(.headline)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if exists {
                Text("A branch named \(branchName) already exists.").font(.caption).foregroundStyle(Theme.danger)
            }
            if naming.choosesStart {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From").font(.subheadline.weight(.medium))
                    TextField("Filter branches", text: $search).textFieldStyle(.roundedBorder)
                    List(selection: $start) {
                        branchSection("Local", remote: false)
                        branchSection("Remote", remote: true)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                    .frame(height: 260)
                }
            }
            Text(note).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Branch", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(branchName.isEmpty || exists)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func branchSection(_ title: String, remote: Bool) -> some View {
        let branches = filtered(remote: remote)
        if !branches.isEmpty {
            Section(title) {
                ForEach(branches) { branch in
                    HStack(spacing: 8) {
                        Image(systemName: remote ? "cloud" : "arrow.triangle.branch").foregroundStyle(Theme.textTertiary)
                        Text(branch.name).lineLimit(1).truncationMode(.middle)
                        if !remote, branch.name == current {
                            Text("current").font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text(branch.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .tag(branch.name)
                }
            }
        }
    }

    private func create() {
        let name = branchName
        guard !name.isEmpty, !exists else { return }
        let start = naming.choosesStart && start == current ? "" : start
        dismiss()
        Task { await repo.perform("Creating \(name)…") { try $0.createBranch(name, from: start.isEmpty ? nil : start) } }
    }
}

// MARK: - Top bar

private struct GitTopBar: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    /// Offered repositories; `nil` means every project's.
    let repositories: [String]?
    let compact: Bool
    /// The wide layout's detail column switch; `nil` where there is no column to hide.
    let showsDetail: Binding<Bool>?
    let locked: Bool
    let confirm: (Confirmation) -> Void
    let name: (Naming) -> Void
    @State private var showsBranches = false

    private var choices: [String] {
        var seen = Set<String>()
        return (repositories ?? model.projects.flatMap(\.allPaths))
            .filter { seen.insert($0).inserted && GitHead.gitDirectory(of: URL(fileURLWithPath: $0)) != nil }
    }

    private var branchTitle: String {
        repo.status?.branch ?? (repo.status?.headSHA.map { "Detached at \(GitLog.short($0))" } ?? "—")
    }

    var body: some View {
        if compact {
            compactBar
        } else {
            wideBar
        }
    }

    private var wideBar: some View {
        HStack(spacing: 0) {
            repositoryMenu
                .frame(minWidth: 150, idealWidth: 300, maxWidth: 300)
            divider
            branchButton
                .frame(minWidth: 150, idealWidth: 280, maxWidth: 280)
            divider
            SyncButton(repo: repo, locked: locked, confirm: confirm)
                .frame(minWidth: 150, idealWidth: 260, maxWidth: 260)
            divider
            Spacer()
            busyLabel
            if let showsDetail {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsDetail.wrappedValue.toggle() }
                } label: {
                    Image(systemName: showsDetail.wrappedValue ? "rectangle.righthalf.inset.filled" : "rectangle.split.2x1")
                        .font(.system(size: 14))
                        .foregroundStyle(showsDetail.wrappedValue ? Theme.textSecondary : Theme.accent)
                        .frame(width: 30, height: 30)
                        .hoverHighlight(cornerRadius: Theme.Radius.chip)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("d", modifiers: [.option, .command])
                .help(showsDetail.wrappedValue ? "Hide Details (⌥⌘D)" : "Show Details (⌥⌘D)")
                .padding(.trailing, 10)
            }
        }
        .frame(height: 52)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Side panel: branch and sync on one row; the repository below when there is a choice.
    private var compactBar: some View {
        VStack(spacing: 0) {
            // Very narrow panels keep the branch name and shrink the sync button to its icon.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    branchButton
                    divider
                    SyncButton(repo: repo, locked: locked, compact: true, confirm: confirm)
                        .frame(width: 170)
                }
                HStack(spacing: 0) {
                    branchButton
                    divider
                    SyncButton(repo: repo, locked: locked, compact: true, iconOnly: true, confirm: confirm)
                        .frame(width: 64)
                }
            }
            .frame(height: 46)
            if choices.count > 1 {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                repositoryMenu
                    .frame(height: 40)
            }
            if repo.busy != nil {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack { busyLabel; Spacer() }.padding(.leading, 12).frame(height: 26)
            }
        }
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var repositoryMenu: some View {
        Menu {
            ForEach(choices, id: \.self) { path in
                Button((path as NSString).lastPathComponent) { repo.root = path }
            }
        } label: {
            segment(symbol: "lock.open", caption: "Current Repository", title: (repo.root as NSString).lastPathComponent, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var branchButton: some View {
        Button {
            showsBranches.toggle()
        } label: {
            segment(symbol: "arrow.triangle.branch", caption: "Current Branch", title: branchTitle, chevron: true)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsBranches, arrowEdge: .bottom) {
            BranchPicker(repo: repo, locked: locked, confirm: confirm, name: name) { showsBranches = false }
        }
    }

    @ViewBuilder
    private var busyLabel: some View {
        if let busy = repo.busy {
            ProgressView().controlSize(.small)
            Text(busy).font(Theme.Font.ui).foregroundStyle(Theme.textSecondary).padding(.trailing, 14)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1)
    }

    private func segment(symbol: String, caption: String, title: String, chevron: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if chevron {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0)
    }
}

/// Fetch, Pull ↓n, Push ↑n or Publish branch, whichever applies, like GitHub Desktop.
private struct SyncButton: View {
    @Bindable var repo: GitRepoModel
    let locked: Bool
    var compact = false
    /// Just the icon and the ↓/↑ count; the title moves to the tooltip.
    var iconOnly = false
    let confirm: (Confirmation) -> Void

    private enum Action { case fetch, pull, push, publish, forcePush }

    private var action: Action {
        guard let status = repo.status else { return .fetch }
        // After a squash the branch and origin have parted ways on purpose: replace, don't pull.
        if repo.squashBackup != nil, status.ahead > 0, status.behind > 0,
           let branch = status.branch, !GitClient.protectedBranches.contains(branch) {
            return .forcePush
        }
        if let branch = status.branch, status.upstream == nil {
            // Already on origin but not tracked: pushing sets the upstream.
            return repo.branches.contains { $0.isRemote && $0.name == "origin/\(branch)" } ? .push : .publish
        }
        if status.behind > 0 { return .pull }
        if status.ahead > 0 { return .push }
        return .fetch
    }

    var body: some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: pending ? .semibold : .regular))
                    .foregroundStyle(pending ? tint : Theme.textSecondary)
                    .frame(width: 18)
                if iconOnly {
                    if let badge { badgeLabel(badge) }
                } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let badge { badgeLabel(badge) }
                    }
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, iconOnly ? 10 : 14)
            .frame(maxHeight: .infinity)
            .background(pending ? tint.opacity(0.10) : .clear)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .disabled(locked || repo.status?.inProgress != nil)
        .help(iconOnly ? "\(title) · \(subtitle)" : "")
        .contextMenu {
            Button("Fetch") { Task { await repo.perform("Fetching origin…") { try $0.fetch() } } }
            Button("Pull") { Task { await repo.perform("Pulling origin…") { try $0.pull() } } }
            Button("Push") { Task { await repo.perform("Pushing origin…") { try $0.push() } } }
        }
    }

    /// "↓4", "↑1 ↓2" on the button's color.
    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(tint, in: Capsule())
            .fixedSize()
    }

    /// Blue for the usual sync, amber when it would replace origin's history.
    private var tint: Color { action == .forcePush ? Theme.warning : Theme.action }

    /// Something to pull, push or publish: the button stands out, as in GitHub Desktop.
    private var pending: Bool { action != .fetch }

    private var title: String {
        switch action {
        case .fetch: "Fetch origin"
        case .pull: "Pull origin"
        case .push: "Push origin"
        case .publish: "Publish branch"
        case .forcePush: "Force Push origin"
        }
    }

    private var symbol: String {
        switch action {
        case .fetch: "arrow.triangle.2.circlepath"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .publish: "icloud.and.arrow.up"
        case .forcePush: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var badge: String? {
        switch action {
        case .pull: "↓\(repo.status?.behind ?? 0)" + ((repo.status?.ahead ?? 0) > 0 ? " ↑\(repo.status?.ahead ?? 0)" : "")
        case .push: "↑\(repo.status?.ahead ?? 0)"
        case .forcePush: "↑\(repo.status?.ahead ?? 0) ↓\(repo.status?.behind ?? 0)"
        default: nil
        }
    }

    private var subtitle: String {
        if action == .publish { return "Publish this branch to origin" }
        if action == .forcePush { return "Replace origin's commits with the squash" }
        guard let fetched = repo.status?.lastFetched else { return "Never fetched" }
        if compact {
            return "Fetched " + fetched.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        return "Last fetched " + fetched.formatted(.relative(presentation: .named))
    }

    private func run() {
        let branch = repo.status?.branch
        Task {
            switch action {
            case .fetch: await repo.perform("Fetching origin…") { try $0.fetch() }
            case .pull: await repo.perform("Pulling origin…") { try $0.pull() }
            case .push:
                let tracked = repo.status?.upstream != nil
                await repo.perform("Pushing origin…") { try $0.push(publishing: tracked ? nil : branch) }
            case .publish: await repo.perform("Publishing \(branch ?? "")…") { try $0.push(publishing: branch) }
            case .forcePush:
                let push = Confirmation(
                    title: "Force push \(branch ?? "")?",
                    message: "Origin's \(branch ?? "branch") is replaced with your squashed history. If someone pushed to it since your last fetch, the push stops instead of overwriting their work.",
                    actions: [.init(title: "Force Push", busyTitle: "Force pushing…", destructive: true) { try $0.forcePush() }]
                )
                confirm(push)
            }
        }
    }
}

/// Branch list with search, switching (with a stash offer), new branch and delete.
private struct BranchPicker: View {
    @Bindable var repo: GitRepoModel
    let locked: Bool
    let confirm: (Confirmation) -> Void
    let name: (Naming) -> Void
    let close: () -> Void
    @State private var search = ""

    private var local: [GitClient.Branch] {
        repo.branches.filter { !$0.isRemote && matches($0) }
    }

    /// Remote branches without a local branch of the same name.
    private var remote: [GitClient.Branch] {
        let localNames = Set(repo.branches.filter { !$0.isRemote }.map(\.name))
        return repo.branches.filter { branch in
            branch.isRemote && matches(branch) && !localNames.contains(String(branch.name.split(separator: "/", maxSplits: 1).last ?? ""))
        }
    }

    private func matches(_ branch: GitClient.Branch) -> Bool {
        search.isEmpty || branch.name.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("New Branch…") {
                    close()
                    name(Naming(title: "New branch", message: "", start: "", choosesStart: true))
                }
                .disabled(locked)
            }
            .padding(10)
            Divider()
            List {
                Section("Branches") {
                    ForEach(local) { branch in row(branch) }
                }
                if !remote.isEmpty {
                    Section("Remote") {
                        ForEach(remote) { branch in row(branch) }
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 380, height: 440)
    }

    private func row(_ branch: GitClient.Branch) -> some View {
        let current = !branch.isRemote && branch.name == repo.status?.branch
        return Button {
            guard !current else { return }
            close()
            switchTo(branch)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: current ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(current ? Theme.accent : Theme.textTertiary)
                    .frame(width: 14)
                Text(branch.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(branch.date.formatted(.relative(presentation: .named)))
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .contextMenu {
            if !branch.isRemote, !current {
                Button("Delete Branch…", role: .destructive) {
                    close()
                    confirm(Confirmation(
                        title: "Delete \(branch.name)?",
                        message: "Git refuses if it has commits not merged anywhere else, so nothing is lost.",
                        actions: [.init(title: "Delete", busyTitle: "Deleting \(branch.name)…", destructive: true) { try $0.deleteBranch(branch.name) }]
                    ))
                }
            }
        }
    }

    /// With uncommitted changes, offer GitHub Desktop's choice: leave them stashed on the
    /// current branch, or bring them along.
    private func switchTo(_ branch: GitClient.Branch) {
        let current = repo.status?.branch ?? "HEAD"
        guard !(repo.status?.files.isEmpty ?? true) else {
            Task { await repo.perform("Switching to \(branch.name)…") { try $0.checkout(branch) } }
            return
        }
        confirm(Confirmation(
            title: "Switch to \(branch.name)?",
            message: "You have uncommitted changes on \(current).",
            actions: [
                .init(title: "Leave My Changes on \(current)", busyTitle: "Stashing and switching…") { client in
                    try client.stash(message: "Mountagent Desk: \(current)")
                    try client.checkout(branch)
                },
                .init(title: "Bring My Changes to \(branch.name)", busyTitle: "Switching to \(branch.name)…") { try $0.checkout(branch) },
            ]
        ))
    }
}

// MARK: - Changes

private struct ChangesList: View {
    @Bindable var repo: GitRepoModel
    let locked: Bool
    let confirm: (Confirmation) -> Void
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { !repo.files.isEmpty && repo.excluded.isEmpty },
                    set: { all in repo.excluded = all ? [] : Set(repo.files.map(\.path)) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                Text("\(repo.files.count) changed file\(repo.files.count == 1 ? "" : "s")")
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(repo.files) { file in
                        FileRow(file: file, included: !repo.excluded.contains(file.path), selected: repo.selectedFile == file.path) { include in
                            if include { repo.excluded.remove(file.path) } else { repo.excluded.insert(file.path) }
                        }
                        .onTapGesture { open(file.path) }
                        .contextMenu { menu(for: file) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for file: GitClient.FileStatus) -> some View {
        let url = URL(fileURLWithPath: repo.root).appendingPathComponent(file.path)
        Button("Discard Changes…", role: .destructive) {
            confirm(Confirmation(
                title: "Discard changes to \(file.path)?",
                message: file.kind == .untracked ? "The file moves to the Trash." : "The file goes back to the last commit. This can't be undone.",
                actions: [.init(title: "Discard", busyTitle: "Discarding…", destructive: true) { client in
                    if file.kind == .untracked {
                        try FileManager.default.trashItem(at: client.root.appendingPathComponent(file.path), resultingItemURL: nil)
                    } else {
                        try client.discard([file])
                    }
                }]
            ))
        }
        .disabled(locked)
        if file.kind == .untracked {
            Button("Ignore File") { Task { await repo.perform("Ignoring…") { try $0.ignore(file.path) } } }
                .disabled(locked)
        }
        Divider()
        Button("Copy Path") {
            Clipboard.copy(file.path)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        if CursorApp.isInstalled {
            Button("Open in Cursor") { CursorApp.open([url]) }
        }
    }
}

private struct FileRow: View {
    let file: GitClient.FileStatus
    let included: Bool
    let selected: Bool
    let toggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { included }, set: { toggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(file.path)
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            Spacer(minLength: 4)
            badge
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(selected ? Theme.accent.opacity(0.22) : .clear)
        .contentShape(Rectangle())
    }

    private var badge: some View {
        let (symbol, color): (String, Color) = switch file.kind {
        case .added, .untracked: ("plus.square.fill", Theme.success)
        case .deleted: ("minus.square.fill", Theme.danger)
        case .renamed: ("arrow.right.square.fill", Theme.accent)
        case .conflicted: ("exclamationmark.triangle.fill", Theme.warning)
        case .modified: ("dot.square.fill", Theme.warning)
        }
        return Image(systemName: symbol)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .help(file.kind.rawValue.capitalized)
    }
}

private struct StashBar: View {
    @Bindable var repo: GitRepoModel
    let stash: GitClient.Stash
    let locked: Bool
    let confirm: (Confirmation) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(Theme.textSecondary)
            Text("Stashed changes").font(Theme.Font.ui).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Discard") {
                confirm(Confirmation(title: "Discard the stashed changes?", message: stash.message, actions: [
                    .init(title: "Discard Stash", busyTitle: "Discarding stash…", destructive: true) { try $0.dropStash(stash) },
                ]))
            }
            Button("Restore") { Task { await repo.perform("Restoring stash…") { try $0.popStash(stash) } } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .controlSize(.small)
        .disabled(locked)
        .padding(10)
        .help(stash.message)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Summary, description and "Commit to <branch>", signed as the project's git account.
private struct CommitBox: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    let locked: Bool

    private var account: GitAccount? {
        let project = model.projects.first { $0.allPaths.contains(repo.root) }
        return model.gitAccount(project?.gitAccountID)
    }

    private var canCommit: Bool {
        !locked && !repo.summary.trimmingCharacters(in: .whitespaces).isEmpty && !repo.included.isEmpty
            && repo.status?.conflicted.isEmpty != false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GitAccountAvatar(account: account, size: 22)
                TextField("Summary (required)", text: $repo.summary)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $repo.details)
                .font(Theme.Font.ui)
                .scrollContentBackground(.hidden)
                .frame(height: 64)
                .padding(4)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if repo.details.isEmpty {
                        Text("Description").font(Theme.Font.ui).foregroundStyle(Theme.textTertiary).padding(.leading, 9).padding(.top, 4).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.stroke))
            Button {
                let paths = repo.included.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
                let summary = repo.summary.trimmingCharacters(in: .whitespaces)
                let details = repo.details
                Task {
                    await repo.perform("Committing…") { try $0.commit(paths: paths, summary: summary, description: details) }
                    if repo.error == nil {
                        repo.summary = ""
                        repo.details = ""
                    }
                }
            } label: {
                Text("Commit \(repo.included.count) file\(repo.included.count == 1 ? "" : "s") to **\(repo.status?.branch ?? "HEAD")**")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(!canCommit)
            if let account {
                Text("Commits as \(account.name) <\(account.email)>")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - History

private struct CommitList: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    let locked: Bool
    let confirm: (Confirmation) -> Void
    let name: (Naming) -> Void
    let squash: ([GitLog.Commit]) -> Void
    let open: (GitLog.Commit) -> Void

    private var viewingOther: Bool { repo.viewsOtherBranch }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Picker("", selection: $repo.historyBranch) {
                    Text("\(repo.status?.branch ?? "HEAD") (current)").tag(String?.none)
                    ForEach(repo.branches.filter { $0.name != repo.status?.branch }) { branch in
                        Text(branch.name).tag(String?.some(branch.name))
                    }
                }
                .labelsHidden()
                AuthorFilter(repo: repo)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if repo.history.isEmpty, !repo.authorFilter.isEmpty {
                        VStack(spacing: 8) {
                            Text("No commits by the people you picked on this branch.")
                                .font(Theme.Font.ui)
                                .foregroundStyle(Theme.textSecondary)
                            Button("Show Everyone") { repo.authorFilter = [] }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                    ForEach(repo.history) { commit in
                        CommitRow(commit: commit, selected: repo.isSelected(commit), account: model.gitAccounts.first { $0.email == commit.email }, webURL: repo.webURL)
                            .onTapGesture {
                                if repo.click(commit, modifiers: NSEvent.modifierFlags) { open(commit) }
                            }
                            .contextMenu {
                                if repo.multiSelection.contains(commit) {
                                    MultiCommitMenu(repo: repo, locked: locked, squash: squash)
                                } else {
                                    menu(for: commit)
                                }
                            }
                    }
                }
            }
            if repo.multiSelection.count > 1 {
                selectionBar
            }
        }
        .onExitCommand { repo.clearMultiSelection() }
    }

    /// "3 commits selected · Squash… · ⋯ · ✕" under the list.
    private var selectionBar: some View {
        let count = repo.multiSelection.count
        return HStack(spacing: 8) {
            Text("\(count) commits selected")
                .font(Theme.Font.uiMedium)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 4)
            if !viewingOther {
                Button {
                    squash(repo.multiSelection)
                } label: {
                    Label("Squash…", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
                .disabled(locked)
            }
            Menu {
                MultiCommitMenu(repo: repo, locked: locked, squash: squash, includesSquash: false)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { repo.clearMultiSelection() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Clear selection (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private func menu(for commit: GitLog.Commit) -> some View {
        let current = repo.status?.branch ?? "HEAD"
        Button(viewingOther ? "Cherry-pick into \(current)" : "Cherry-pick (again) into \(current)") {
            Task { await repo.perform("Cherry-picking \(commit.shortSHA)…") { try $0.cherryPick(commit) } }
        }
        .disabled(locked)
        if !viewingOther {
            Button("Revert Changes in Commit") {
                Task { await repo.perform("Reverting \(commit.shortSHA)…") { try $0.revert(commit) } }
            }
            .disabled(locked)
        }
        Button("Create Branch from Commit…") {
            name(Naming(title: "New branch from \(commit.shortSHA)", message: commit.subject, start: commit.sha))
        }
        .disabled(locked)
        Divider()
        if !viewingOther {
            Menu("Reset \(current) to This Commit") {
                Button("Soft: keep changes staged") { reset(commit, .soft) }
                Button("Mixed: keep changes in files") { reset(commit, .mixed) }
                Button("Hard: discard all later changes…", role: .destructive) { reset(commit, .hard) }
            }
            .disabled(locked)
        }
        Button("Check Out This Commit…") {
            confirm(Confirmation(
                title: "Check out \(commit.shortSHA)?",
                message: "You'll be on a detached HEAD: new commits there belong to no branch until you create one.",
                actions: [.init(title: "Check Out", busyTitle: "Checking out…") { try $0.checkoutDetached(commit.sha) }]
            ))
        }
        .disabled(locked)
        Divider()
        CommitMenu(commit: commit)
    }

    private func reset(_ commit: GitLog.Commit, _ mode: GitClient.ResetMode) {
        let current = repo.status?.branch ?? "HEAD"
        let message: String = switch mode {
        case .soft: "Later commits are undone; their changes stay staged."
        case .mixed: "Later commits are undone; their changes stay in your files."
        case .hard: "Later commits and all uncommitted changes are thrown away. This can't be undone."
        }
        confirm(Confirmation(
            title: "Reset \(current) to \(commit.shortSHA)?",
            message: message,
            actions: [.init(title: "Reset (\(mode.rawValue))", busyTitle: "Resetting…", destructive: mode == .hard) { try $0.reset(to: commit.sha, mode: mode) }]
        ))
    }
}

/// Who History shows: everyone, or the people ticked in a popover (several at once).
private struct AuthorFilter: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    @State private var showing = false
    @State private var search = ""

    private var picked: [GitLog.Author] {
        repo.authors.filter { repo.authorFilter.contains($0.email) }
    }

    var body: some View {
        let count = repo.authorFilter.count
        Button { showing.toggle() } label: {
            HStack(spacing: 5) {
                if count == 0 {
                    Image(systemName: "person.2").font(.system(size: 11))
                    Text("Everyone")
                } else {
                    HStack(spacing: -5) {
                        ForEach(picked.prefix(3)) { author in
                            avatar(author, size: 16)
                        }
                    }
                    // Picked people may have no commits on the branch shown now.
                    Text(count == 1 ? picked.first?.name ?? "1 person" : "\(count) people")
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.Font.ui)
            .foregroundStyle(count == 0 ? Theme.textSecondary : Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(count == 0 ? Color.clear : Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .hoverHighlight(cornerRadius: Theme.Radius.chip)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Show the commits of the people you pick")
        .popover(isPresented: $showing, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? repo.authors : repo.authors.filter { $0.name.lowercased().contains(query) || $0.email.lowercased().contains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                TextField("Find a person", text: $search).textFieldStyle(.plain)
                if !repo.authorFilter.isEmpty {
                    Button("Everyone") { repo.authorFilter = [] }
                        .controlSize(.small)
                        .help("Show everyone's commits")
                }
            }
            .font(Theme.Font.ui)
            .padding(10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { author in
                        row(author)
                    }
                    if shown.isEmpty {
                        Text("No one matches.")
                            .font(Theme.Font.ui)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(10)
                    }
                }
                .padding(4)
            }
            // A popover gives a scroll view no height of its own; size it to the rows.
            .frame(height: min(max(CGFloat(shown.count) * 36 + 8, 50), 360))
        }
        .frame(width: 320)
    }

    private func row(_ author: GitLog.Author) -> some View {
        let on = repo.authorFilter.contains(author.email)
        return Button {
            if on { repo.authorFilter.remove(author.email) } else { repo.authorFilter.insert(author.email) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                avatar(author, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author.name).font(Theme.Font.uiMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(author.email).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text("\(author.commits)")
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(.plain)
    }

    private func avatar(_ author: GitLog.Author, size: CGFloat) -> some View {
        let account = model.gitAccounts.first { $0.email.caseInsensitiveCompare(author.email) == .orderedSame }
        return GitAccountAvatar(account: account ?? GitAccount(label: author.name, name: author.name, email: author.email, sshKeyPath: nil), size: size)
    }
}

private struct CommitRow: View {
    let commit: GitLog.Commit
    let selected: Bool
    let account: GitAccount?
    var webURL: URL?

    /// "21 Oct, 14:05"; the year only when it isn't this one.
    static func dateText(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let day = sameYear ? date.formatted(.dateTime.day().month(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated).year())
        return day + ", " + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    var body: some View {
        let references = commit.references
        VStack(alignment: .leading, spacing: 4) {
            subject(references)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                GitAccountAvatar(account: account ?? GitAccount(label: commit.author, name: commit.author, email: commit.email, sshKeyPath: nil), size: 16)
                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named))) · \(Self.dateText(commit.date))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .help(commit.date.formatted(date: .complete, time: .standard))
                Spacer(minLength: 4)
                if let number = references.pullRequest {
                    ReferenceChip(title: "#\(number)", symbol: "arrow.triangle.pull", tint: Theme.action,
                                  help: webURL == nil ? "Pull request #\(number)" : "Open pull request #\(number) on GitHub") {
                        if let webURL { NSWorkspace.shared.open(webURL.appending(path: "pull/\(number)")) }
                    }
                }
                ForEach(references.tasks, id: \.self) { task in
                    ReferenceChip(title: task, symbol: "checklist", tint: Theme.Tool.agent, help: "Put \"sync \(task)\" in the chat") {
                        NotificationCenter.default.post(name: .insertIntoComposer, object: nil, userInfo: ["text": "sync \(task)"])
                    }
                }
                if !commit.refs.isEmpty {
                    Image(systemName: "tag").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                        .help(commit.refs.joined(separator: ", "))
                }
            }
        }
        .opacity(commit.isMerge && !selected ? 0.8 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.22) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .contentShape(Rectangle())
    }
}

extension CommitRow {
    /// The subject with its work-item code in that code's color and "#99" in the link color.
    /// Merge commits stay quieter so real work stands out.
    func subject(_ references: GitLog.References) -> Text {
        var text = AttributedString(commit.subject)
        text.foregroundColor = commit.isMerge ? Theme.textSecondary : Theme.textPrimary
        if let code = references.code, let label = references.label, let range = text.range(of: label) {
            text[range].foregroundColor = Theme.hue(for: code)
        }
        if let number = references.pullRequest, let range = text.range(of: "#\(number)") {
            text[range].foregroundColor = Theme.action
        }
        return Text(text)
    }
}

/// A small tinted capsule for a pull request or task in a commit row.
private struct ReferenceChip: View {
    let title: String
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(tint.opacity(hovering ? 0.24 : 0.13), in: Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Actions on several selected commits, for the context menu and the selection bar.
private struct MultiCommitMenu: View {
    @Bindable var repo: GitRepoModel
    let locked: Bool
    let squash: ([GitLog.Commit]) -> Void
    var includesSquash = true

    private var commits: [GitLog.Commit] { repo.multiSelection }
    private var current: String { repo.status?.branch ?? "HEAD" }
    private var viewingOther: Bool { repo.viewsOtherBranch }

    var body: some View {
        let count = commits.count
        if includesSquash, !viewingOther {
            Button("Squash \(count) Commits…") { squash(commits) }
                .disabled(locked)
            Divider()
        }
        Button("Cherry-pick \(count) Commits into \(current)") {
            let ordered = Array(commits.reversed())   // oldest first
            Task {
                await repo.perform("Cherry-picking \(count) commits…") { client in
                    for commit in ordered { try client.cherryPick(commit) }
                }
            }
        }
        .disabled(locked)
        if !viewingOther {
            Button("Revert \(count) Commits") {
                let ordered = commits   // newest first, so each revert applies cleanly
                Task {
                    await repo.perform("Reverting \(count) commits…") { client in
                        for commit in ordered { try client.revert(commit) }
                    }
                }
            }
            .disabled(locked)
        }
        Divider()
        Button("Copy SHAs") {
            Clipboard.copy(commits.reversed().map(\.sha).joined(separator: "\n"))
        }
        Button("Mention in Chat") {
            let mention = commits.reversed().map { "\($0.shortSHA) (\"\($0.subject)\")" }.joined(separator: ", ")
            NotificationCenter.default.post(name: .insertIntoComposer, object: nil, userInfo: ["text": "commits " + mention])
        }
    }
}

/// The detail column while several commits are selected: what they are, and what to do.
private struct MultiCommitPane: View {
    @Environment(AppModel.self) private var model
    @Bindable var repo: GitRepoModel
    let locked: Bool
    let squash: ([GitLog.Commit]) -> Void

    var body: some View {
        let commits = repo.multiSelection
        let authors = Set(commits.map(\.author)).sorted()
        let viewingOther = repo.viewsOtherBranch
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(commits.count) commits selected")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let newest = commits.first, let oldest = commits.last {
                    Text("\(oldest.date.formatted(date: .abbreviated, time: .shortened)) – \(newest.date.formatted(date: .abbreviated, time: .shortened)) · \(authors.joined(separator: ", "))")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(commits.reversed()) { commit in
                    HStack(spacing: 8) {
                        Text(commit.shortSHA)
                            .font(Theme.Font.toolTarget)
                            .foregroundStyle(Theme.textTertiary)
                        Text(commit.subject)
                            .font(Theme.Font.ui)
                            .foregroundStyle(commit.isMerge ? Theme.textSecondary : Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                }
            }
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            HStack(spacing: 8) {
                if !viewingOther {
                    Button {
                        squash(commits)
                    } label: {
                        Label("Squash into One…", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.action)
                }
                Menu("More") {
                    MultiCommitMenu(repo: repo, locked: locked, squash: squash, includesSquash: false)
                }
                .fixedSize()
                Spacer()
            }
            .disabled(locked)
            Text("⌘-click to add or remove a commit, ⇧-click to select a run. Esc clears.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }
}

/// Confirms a squash: the commits, the message (prefilled, editable) and what happens to origin.
private struct SquashSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repo: GitRepoModel
    let plan: GitClient.SquashPlan
    @State private var message: String

    init(repo: GitRepoModel, plan: GitClient.SquashPlan) {
        self.repo = repo
        self.plan = plan
        _message = State(initialValue: plan.message)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.action.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Squash \(plan.commits.count) commits on \(plan.branch)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("They become one commit by \(plan.commits.first?.author ?? "the first author"). Later commits are replayed on top.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(plan.commits) { commit in
                    HStack(spacing: 8) {
                        Text(commit.shortSHA).font(Theme.Font.toolTarget).foregroundStyle(Theme.textTertiary)
                        Text(commit.subject).font(Theme.Font.ui).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                }
            }
            .padding(.vertical, 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Message").font(Theme.Font.uiMedium).foregroundStyle(Theme.textSecondary)
                TextEditor(text: $message)
                    .font(Theme.Font.code)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 130)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
            }

            if plan.isPushed {
                Label("These commits are already on origin. After squashing, Sync becomes Force Push to replace them there; anyone else on \(plan.branch) will need to reset to it.", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("You can undo it afterwards.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Squash \(plan.commits.count) Commits") {
                    let plan = plan
                    let message = message
                    dismiss()
                    Task { await repo.perform("Squashing \(plan.commits.count) commits…") { try $0.squash(plan, message: message) } }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Theme.background)
    }
}

/// Commit header, then its files beside the selected file's numbered diff.
private struct CommitDetailPane: View {
    let commit: GitLog.Commit
    let root: String
    /// Side panel: files above the diff instead of beside it.
    let compact: Bool
    @State private var detail: GitLog.Detail?
    @State private var file: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                if let body = detail?.message.split(separator: "\n", maxSplits: 1).dropFirst().first {
                    ScrollView {
                        Text(String(body).trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(Theme.Font.code)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                }
                HStack(spacing: 8) {
                    Text(commit.author).font(Theme.Font.ui).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "number").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    Text(commit.shortSHA).font(Theme.Font.toolTarget).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    Text(commit.formattedDate).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let detail {
                        DiffStat(additions: detail.files.reduce(0) { $0 + $1.additions }, deletions: detail.files.reduce(0) { $0 + $1.deletions })
                    }
                }
            }
            .padding(12)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }

            if compact {
                VSplitView {
                    fileList
                        .frame(minHeight: 70, idealHeight: 150)
                    filePane
                        .frame(minHeight: 200)
                }
            } else {
                HSplitView {
                    fileList
                        .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    filePane
                }
            }
        }
        .task(id: commit.sha) {
            file = nil
            let url = URL(fileURLWithPath: root)
            let commit = commit
            detail = await Task.detached { GitLog.detail(of: commit, in: url) }.value
            file = detail?.files.first?.path
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            Text("\(detail?.files.count ?? 0) changed file\(detail?.files.count == 1 ? "" : "s")")
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(detail?.files ?? []) { change in
                        HStack {
                            Text(change.path).font(Theme.Font.ui).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.head)
                            Spacer()
                            DiffStat(additions: change.additions, deletions: change.deletions).font(Theme.Font.caption)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(file == change.path ? Theme.accent.opacity(0.22) : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { file = change.path }
                    }
                }
            }
        }
        .background(Theme.sidebar)
    }

    @ViewBuilder
    private var filePane: some View {
        if let file {
            FileDiffPane(title: file, load: { [commit, root] in GitLog.diff(of: commit, file: file, in: URL(fileURLWithPath: root)) }, key: "\(commit.sha)|\(file)")
        } else {
            PlaceholderPane(symbol: "doc.text", title: "Select a file", text: "")
        }
    }
}

// MARK: - Shared panes

/// A file's diff with old and new line numbers, as GitHub Desktop shows it.
private struct FileDiffPane: View {
    let title: String
    let load: @Sendable () -> String
    let key: String
    @State private var diff = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((title as NSString).deletingLastPathComponent.isEmpty ? "" : (title as NSString).deletingLastPathComponent + "/")
                    .foregroundStyle(Theme.textTertiary)
                + Text((title as NSString).lastPathComponent)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .font(Theme.Font.ui)
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            NumberedDiff(diff: diff)
        }
        .task(id: key) {
            let load = load
            diff = await Task.detached { load() }.value
        }
    }
}

struct NumberedDiff: View {
    let diff: String

    private struct Line: Identifiable {
        var id: Int
        var old: Int?
        var new: Int?
        var text: String
        var kind: Character
    }

    private var lines: [Line] {
        var result: [Line] = []
        var old = 0, new = 0
        var started = false
        for raw in diff.components(separatedBy: "\n") {
            if let match = raw.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                old = Int(match.1) ?? 0
                new = Int(match.2) ?? 0
                started = true
                result.append(Line(id: result.count, text: raw, kind: "@"))
                continue
            }
            // Context lines start with a space; an empty string is only the text's trailing newline.
            guard started, !raw.isEmpty else { continue }
            if raw.hasPrefix("+") {
                result.append(Line(id: result.count, new: new, text: String(raw.dropFirst()), kind: "+"))
                new += 1
            } else if raw.hasPrefix("-") {
                result.append(Line(id: result.count, old: old, text: String(raw.dropFirst()), kind: "-"))
                old += 1
            } else if raw.hasPrefix("\\") {
                continue
            } else {
                result.append(Line(id: result.count, old: old, new: new, text: String(raw.dropFirst()), kind: " "))
                old += 1
                new += 1
            }
        }
        return result
    }

    var body: some View {
        let lines = lines
        if lines.isEmpty {
            PlaceholderPane(symbol: "doc", title: diff.isEmpty ? "Loading…" : "No text changes", text: diff.contains("Binary files") ? "Binary file" : "")
        } else {
            GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(spacing: 0) {
                            Text(line.old.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
                            Text(line.new.map(String.init) ?? "").frame(width: 46, alignment: .trailing)
                            Text(line.kind == "@" ? "" : String(line.kind)).frame(width: 22)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == "@" ? Theme.textTertiary : Theme.textPrimary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(Theme.Font.code)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(minHeight: 19)
                        .background(background(line.kind))
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 4)
                // Pin short diffs to the top-left instead of the scroll view's centre.
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
            }
            }
            .background(Theme.codeBackground)
        }
    }

    private func background(_ kind: Character) -> Color {
        switch kind {
        case "+": Theme.success.opacity(0.14)
        case "-": Theme.danger.opacity(0.14)
        case "@": Theme.accent.opacity(0.08)
        default: .clear
        }
    }
}

private struct PlaceholderPane: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
            Text(title).font(Theme.Font.title).foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Text(text).font(Theme.Font.ui).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
            }
        }
        .font(Theme.Font.ui)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
