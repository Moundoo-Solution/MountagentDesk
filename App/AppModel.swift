import MountagentDeskKit
import AppKit
import SwiftUI
import Observation

/// App state on the main actor. Views read it and call its methods; all file and process
/// work goes through MountagentDeskKit.
@MainActor
@Observable
final class AppModel {
    private(set) var projects: [Project] = []
    private(set) var sessions: [UUID: ChatSession] = [:]
    /// The chat area's panes. Saved, so the split and its sessions come back next launch.
    private(set) var grid: PaneGrid = AppModel.loadGrid() {
        didSet { if grid != oldValue { Self.saveGrid(grid) } }
    }
    /// The session in the focused pane: what the sidebar highlights, the right panel shows
    /// and menu commands act on. Setting it opens that session in the focused pane.
    var selectedSessionID: UUID? {
        get { grid.focusedSession }
        set {
            grid.open(newValue)
            refreshDirty()
        }
    }
    /// Working folders with uncommitted changes (the `*` after the branch). Only the selected
    /// session's folder is looked at, and only while the app is in use: git status on a big
    /// checkout isn't free.
    private(set) var dirtyFolders: Set<String> = []
    @ObservationIgnored private var dirtyTimer: Timer?
    /// Project whose rules and skills sheet is open.
    var contextProject: Project?
    /// Project whose folders sheet is open.
    var foldersProject: Project?
    private(set) var running: [UUID: AgentRun] = [:]
    /// Sessions whose turn waits for its checkpoint; a stop then cancels the turn.
    private(set) var preparing: Set<UUID> = []
    @ObservationIgnored private var stoppedWhilePreparing: Set<UUID> = []
    /// Permission requests an agent is waiting on, by request id.
    private var pendingPermissions: [String: PermissionRequest] = [:]
    /// Questions waiting per session, so checking a session (sidebar, panes) doesn't scan
    /// its items; also the Dock badge.
    private var pendingCounts: [UUID: Int] = [:] {
        didSet {
            let total = pendingCounts.values.reduce(0, +)
            NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
        }
    }
    /// Prompts kept for reuse in the composer.
    private(set) var promptTemplates: [PromptTemplate] = []
    /// The ⌘K session switcher is open.
    var showsSwitcher = false
    /// The ⌘T quick launch sheet is open.
    var showsQuickLaunch = false
    /// It opens on a terminal session rather than an agent (⇧⌘T).
    var quickLaunchesTerminal = false

    /// A new session of `agent` in `project`, or, with a branch, in a worktree on that
    /// branch (checked out if it exists, else made from HEAD); `message` goes first. With a
    /// `command`, a terminal session running it instead.
    func quickLaunch(in project: Project, agent: AgentKind, branch: String, message: String, command: String? = nil) {
        let name = branch.trimmingCharacters(in: .whitespaces)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        func begin(_ session: ChatSession) {
            if let command {
                let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
                update(session.id) {
                    $0.command = line
                    $0.title = TerminalCommands.title(for: line)
                }
                persist(session.id)
            } else if !text.isEmpty {
                send(text, attachments: [], in: session.id)
            }
        }
        guard !name.isEmpty else {
            begin(newSession(in: project, agent: agent))
            return
        }
        let repository = project.url
        let id = UUID()
        Task {
            do {
                let created = try await Task.detached { () -> GitWorktree.Created in
                    guard GitCheckpoint.isRepository(repository) else {
                        throw NSError(domain: "Worktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(repository.lastPathComponent) isn't the top folder of a git repository."])
                    }
                    return try GitWorktree.create(in: repository, branch: name, id: id)
                }.value
                let session = newSession(in: project, agent: agent)
                update(session.id) {
                    $0.worktree = created.path.path
                    $0.worktreeBranch = created.branch
                    $0.branch = created.branch
                }
                persist(session.id)
                begin(session)
            } catch {
                alert = "Couldn't make a worktree on \(name): \(error.localizedDescription)"
            }
        }
    }

    func savePromptTemplates(_ templates: [PromptTemplate]) {
        promptTemplates = templates
        do {
            try store.save(templates, named: "prompt-templates")
        } catch {
            alert = "Could not save the prompts: \(error.localizedDescription)"
        }
    }

    /// Asks for a name and keeps `text` as a prompt.
    func saveAsTemplate(_ text: String) {
        let question = NSAlert()
        question.messageText = "Save as a prompt"
        question.informativeText = "Pick it later from the prompts menu, or type / and part of its name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Name"
        field.stringValue = String(text.split(separator: "\n").first?.prefix(50) ?? "")
        question.accessoryView = field
        question.addButton(withTitle: "Save")
        question.addButton(withTitle: "Cancel")
        question.window.initialFirstResponder = field
        guard question.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        savePromptTemplates(promptTemplates + [PromptTemplate(title: title, text: text)])
    }
    /// What each session's composer holds, kept while switching sessions.
    var drafts: [UUID: String] = [:]
    /// A message written while the agent was busy, sent when its turn ends.
    struct QueuedMessage {
        var text: String
        var attachments: [String]
        var images: [URL]
    }
    private(set) var queued: [UUID: QueuedMessage] = [:]
    private(set) var lastResults: [UUID: TurnResult] = [:]
    private(set) var cursorModels = AgentKind.cursor.builtInModels {
        didSet { cursorFamilies = ModelCatalog.cursorFamilies(from: cursorModels) }
    }
    private(set) var cursorFamilies = ModelCatalog.cursorFamilies(from: AgentKind.cursor.builtInModels)
    var alert: String?

    // Agents' accounts and usage
    private(set) var accounts: [AgentKind: AgentAccount] = [:]
    /// Agents switched on in Settings; the others are hidden from pickers and not probed.
    private(set) var enabledAgents: Set<AgentKind> = AppSettings.enabledAgents
    /// Codex's models with their efforts, from `codex debug models`.
    private(set) var codexModels: [CodexProvider.Model] = []
    /// Copilot's models, from `copilot help config`.
    private(set) var copilotModels = AgentKind.copilot.builtInModels
    /// OpenCode's `provider/model`s, from `opencode models`.
    private(set) var openCodeModels = AgentKind.opencode.builtInModels
    private(set) var checkingAccounts = false
    /// Claude's plan limits from `/usage`, refreshed in the background.
    private(set) var planUsage: PlanUsage?
    /// Codex's limits as its last turn saw them, and Copilot's monthly quotas.
    private(set) var codexUsage: PlanUsage?
    private(set) var copilotUsage: CopilotLimits.Result?
    private(set) var cursorUsage: CursorUsage?
    private(set) var cursorUsageProblem: String?
    private var usageTimer: Timer?
    private(set) var ledger = UsageLedger()
    /// Claude Code's and Codex's own logs on this Mac at API prices, in the app or not.
    private(set) var localUsage: [LocalUsage.Entry] = []
    private var scanningLocalUsage = false
    /// The install / sign-in / update command shown in the setup terminal.
    var setupTask: SetupTask?
    /// Git identities + SSH keys the user switches between per project.
    private(set) var gitAccounts: [GitAccount] = []
    /// SSH servers, linked to projects like git accounts.
    private(set) var servers: [Server] = []
    /// Sign-ins servers share (user, key, password in the keychain), like Termius's keychain.
    private(set) var serverCredentials: [ServerCredential] = []
    /// Commands run on each server (keyed by the server id's string), for the Servers panel.
    private(set) var serverHistories: [String: ServerCommandHistory] = [:]
    /// The user's own commands for the Servers panel, after the built-in ones.
    private(set) var serverSnippets: [ServerSnippet] = []
    /// Holds the `mountagent-server` script; put on agents' PATH while they may read servers.
    private var serverHelperDirectory: URL?
    /// Tokens of the agent runs that may use `mountagent-server`, with their project. A token
    /// lives for one run; the helper's requests are checked against it, never against
    /// anything the agent could set or edit.
    private var helperGrants: [String: UUID] = [:]
    private var helperListener: ServerBroker.Listener?
    /// Live branch of every project folder.
    let branches = BranchMonitor()

    struct SetupTask: Identifiable {
        /// Which window shows the terminal: the one the request came from.
        enum Host { case main, settings }

        let id = UUID()
        /// The agent being set up; nil for other tasks (GitHub sign-in), which set `symbolName`.
        let kind: AgentKind?
        let title: String
        let command: String
        var host: Host = .main
        /// Header icon when the task isn't about an agent (e.g. GitHub sign-in).
        var symbolName: String?
        /// Replaces the sheet's usual "a browser window opens…" line.
        var hint: String?
        /// Set for sign-ins that print a link and wait for a pasted code.
        var signIn: AgentSetup.SignInFlow?
    }

    /// Binding for `.sheet(item:)` in one host window.
    func setupBinding(for host: SetupTask.Host) -> Binding<SetupTask?> {
        Binding(
            get: { self.setupTask?.host == host ? self.setupTask : nil },
            set: { if $0 == nil, self.setupTask?.host == host { self.setupFinished() } }
        )
    }

    private let store: ProjectStore

    init(store: ProjectStore = ProjectStore(root: ProjectStore.defaultRoot())) {
        self.store = store
        AppSettings.importLegacySettings()
        load()
        // Resolving the login shell's PATH can take a moment; do it before the first send.
        Task.detached(priority: .utility) { _ = ExecutableLocator.searchPath }
        refreshCursorModels()
        refreshCodexModels()
        refreshCopilotModels()
        refreshOpenCodeModels()
        prefetchGitHubToken()
        ledger = store.load(UsageLedger.self, named: "usage") ?? UsageLedger()
        planUsage = store.load(PlanUsage.self, named: "plan-usage")
        gitAccounts = store.load([GitAccount].self, named: "git-accounts") ?? []
        if gitAccounts.isEmpty {
            // Start from what the machine already uses (git and ssh config, read off the main thread).
            Task.detached(priority: .utility) {
                guard let existing = GitAccountImport.current() else { return }
                await MainActor.run {
                    if self.gitAccounts.isEmpty { self.saveGitAccounts([existing]) }
                }
            }
        }
        servers = store.load([Server].self, named: "servers") ?? []
        serverCredentials = store.load([ServerCredential].self, named: "server-credentials") ?? []
        let moved = ServerCredential.migrate(try? Data(contentsOf: store.root.appendingPathComponent("servers.json")), servers: &servers)
        if !moved.isEmpty {
            saveCredentials(serverCredentials + moved)
            saveServers(servers)
        }
        applyAgentAccessFromKeychain()
        serverSnippets = store.load([ServerSnippet].self, named: "server-snippets") ?? []
        promptTemplates = store.load([PromptTemplate].self, named: "prompt-templates") ?? PromptTemplate.defaults
        serverHistories = store.load([String: ServerCommandHistory].self, named: "server-history") ?? [:]
        ServerTerminals.shared.onCommand = { [weak self] serverID, command in
            self?.updateHistory(of: serverID) { $0.record(command) }
        }
        if let executable = Bundle.main.executablePath {
            serverHelperDirectory = try? ServerHelper.installWrapper(executable: executable, in: store.root)
        }
        startHelperListener()
        cursorUsage = store.load(CursorUsage.self, named: "cursor-usage")
        refreshAccounts()
        refreshPlanUsage()
        refreshCursorUsage()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPlanUsage()
                self?.refreshCursorUsage()
            }
        }
        dirtyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.isActive { self?.refreshDirty() } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDirty() }
        }
    }

    func isDirty(_ folder: URL) -> Bool {
        dirtyFolders.contains(folder.path)
    }

    /// Looks again whether the selected session's folder has uncommitted changes.
    func refreshDirty() {
        guard let session = selectedSession, let project = project(session.projectID) else { return }
        let folder = workRoot(of: session, project: project)
        Task.detached(priority: .utility) {
            let dirty = GitClient(root: folder).status()?.files.isEmpty == false
            await MainActor.run {
                guard self.dirtyFolders.contains(folder.path) != dirty else { return }
                if dirty { self.dirtyFolders.insert(folder.path) } else { self.dirtyFolders.remove(folder.path) }
            }
        }
    }

    // MARK: Lookup

    /// Newest first; archived sessions only when asked for.
    func sessions(of projectID: UUID, includingArchived: Bool = false) -> [ChatSession] {
        sessions.values
            .filter { $0.projectID == projectID && (includingArchived || !$0.archived) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func archivedSessions(of projectID: UUID) -> [ChatSession] {
        sessions.values
            .filter { $0.projectID == projectID && $0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Takes a session out of the sidebar's list (or back), and out of any pane.
    func setArchived(_ archived: Bool, for sessionID: UUID) {
        guard sessions[sessionID] != nil, running[sessionID] == nil || !archived else { return }
        update(sessionID) { $0.archived = archived }
        persist(sessionID)
        if archived {
            SessionTerminals.shared.stop(sessionID)
            grid.remove(sessionID)
            if selectedSessionID == sessionID { selectedSessionID = nil }
        }
    }

    /// "$1.20 · 340k tokens · 18 turns" for the last 30 days, or nil before any turn.
    func usageSummary(of project: Project) -> String? {
        let total = ledger.total(forProject: project.id, lastDays: 30)
        guard total.turns > 0 else { return nil }
        let tokens = total.totalTokens >= 1000 ? "\(total.totalTokens / 1000)k" : String(total.totalTokens)
        return [total.hasCost ? String(format: "$%.2f", total.costUSD) : nil, "\(tokens) tokens", "\(total.turns) turn\(total.turns == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "≈ $41.20 at API prices" for the last 30 days of Claude Code and Codex in the
    /// project's folder (and its worktrees), from their own logs; nil when there's none.
    func apiEquivalent(of project: Project) -> String? {
        let total = LocalUsage.total(of: localUsage, folder: project.path, lastDays: 30)
        guard total.costUSD > 0 else { return nil }
        return "≈ \(total.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2)))) at API prices"
    }

    /// Every project's daily usage as CSV, for billing clients.
    func exportUsageCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Mountagent usage.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        do {
            try ledger.projectCSV(names: names).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Saves the session as Markdown where the user picks.
    func exportMarkdown(_ sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = SessionExport.fileName(for: session)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionExport.markdown(session, projectName: project(session.projectID)?.name).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alert = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func project(_ id: UUID?) -> Project? {
        projects.first { $0.id == id }
    }

    var selectedSession: ChatSession? {
        selectedSessionID.flatMap { sessions[$0] }
    }

    /// Working, or about to (taking the turn's checkpoint first).
    func isRunning(_ sessionID: UUID) -> Bool {
        running[sessionID] != nil || preparing.contains(sessionID)
    }

    /// True while an agent runs in a project that includes this folder.
    func isRepositoryBusy(_ path: String) -> Bool {
        running.keys.contains { id in
            guard let session = sessions[id], let project = project(session.projectID) else { return false }
            return project.allPaths.contains(path)
        }
    }

    /// The repository the Git window opens on: the selected session's main folder.
    var defaultRepository: String? {
        project(selectedSession?.projectID)?.path ?? projects.first?.path
    }

    func hasPendingPermission(_ sessionID: UUID) -> Bool {
        pendingCounts[sessionID, default: 0] > 0
    }

    func models(for agent: AgentKind) -> [AgentModel] {
        switch agent {
        case .claude, .antigravity, .gemini: agent.builtInModels
        case .cursor: cursorModels
        case .codex: agent.builtInModels + codexModels.map(\.model)
        case .copilot: copilotModels
        case .opencode: openCodeModels
        }
    }

    /// Enabled agents in their usual order.
    var agentChoices: [AgentKind] {
        AgentKind.allCases.filter(enabledAgents.contains)
    }

    func isEnabled(_ kind: AgentKind) -> Bool {
        enabledAgents.contains(kind)
    }

    /// Switches an agent on or off. The last one can't be turned off.
    func setEnabled(_ kind: AgentKind, _ enabled: Bool) {
        var agents = enabledAgents
        if enabled { agents.insert(kind) } else { agents.remove(kind) }
        guard !agents.isEmpty else { return }
        enabledAgents = agents
        AppSettings.setEnabledAgents(agents)
        if enabled {
            refreshAccounts()
            if kind == .codex { refreshCodexModels() }
            if kind == .copilot { refreshCopilotModels() }
            if kind == .opencode { refreshOpenCodeModels() }
        }
    }

    /// Efforts the session's agent and model take: Claude's fixed list, the Codex model's
    /// own list; empty where effort isn't a separate choice (Cursor folds it into the model).
    func efforts(for session: ChatSession) -> [String] {
        switch session.agent {
        case .claude, .antigravity, .copilot: Effort.levels
        case .codex:
            codexModels.first { $0.model.id == session.models[.codex] }?.efforts
                ?? codexModels.first?.efforts ?? ["low", "medium", "high", "xhigh"]
        case .cursor, .gemini, .opencode: []
        }
    }

    private var runner: AgentRunner {
        AgentRunner(locator: ExecutableLocator(overrides: AppSettings.executableOverrides))
    }

    // MARK: Projects

    private func load() {
        var problems: [String] = []
        do {
            projects = try store.loadProjects()
        } catch {
            // Keep a copy: the next save writes the file anew.
            let copy = store.setAside(store.projectsFileURL)
            problems.append("projects.json couldn't be read (\(error.localizedDescription)). " + (copy.map { "A copy is at \($0.path)." } ?? "No copy could be made."))
        }
        var setAside: [URL] = []
        for project in projects {
            let loaded = store.loadSessionsSettingAsideDamage(of: project.id)
            setAside += loaded.setAside
            for var session in loaded.sessions {
                // The agent that asked is gone after a restart, and so is any tool it ran.
                for index in session.items.indices {
                    if session.items[index].permissionState == .pending { session.items[index].permissionState = .expired }
                    if session.items[index].toolStatus == .running { session.items[index].toolStatus = .failed }
                }
                sessions[session.id] = session
            }
        }
        if !setAside.isEmpty {
            problems.append("\(setAside.count) session file\(setAside.count == 1 ? "" : "s") couldn't be read and \(setAside.count == 1 ? "was" : "were") moved aside, next to the others: \(setAside.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        if !problems.isEmpty { alert = problems.joined(separator: "\n\n") }
        grid.keep(only: Set(sessions.keys))
        if selectedSessionID == nil {
            selectedSessionID = projects.first.flatMap { sessions(of: $0.id).first?.id }
        }
        watchBranches()
    }

    /// The first folder becomes the main one. With several folders the folders sheet opens,
    /// so the main folder can be confirmed and the project named.
    func addProject(at urls: [URL]) {
        guard let primary = urls.first else { return }
        if urls.count == 1, let existing = projects.first(where: { $0.path == primary.path }) {
            selectedSessionID = sessions(of: existing.id).first?.id ?? newSession(in: existing).id
            return
        }
        var project = Project(name: primary.lastPathComponent, path: primary.path, defaultAgent: AppSettings.defaultAgent)
        project.addFolders(urls.dropFirst().map(\.path))
        projects.append(project)
        sortProjects()
        saveProjects()
        newSession(in: project)
        if urls.count > 1 { foldersProject = project }
    }

    func chooseProjectFolder() {
        let urls = Self.chooseFolders(
            prompt: "Add Project",
            message: "Choose one or more folders. The agents work in the first; the others are added with --add-dir."
        )
        if !urls.isEmpty { addProject(at: urls) }
    }

    static func chooseFolders(prompt: String, message: String, in directory: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Saves changes from the folders sheet. A new main folder means a new working directory,
    /// where the CLIs can't resume their old sessions, so those start over with a handoff.
    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let movedRoot = projects[index].path != project.path
        projects[index] = project
        sortProjects()
        saveProjects()
        guard movedRoot else { return }
        for session in sessions(of: project.id, includingArchived: true) {
            update(session.id) {
                $0.agentSessionIDs = [:]
                $0.seenCounts = [:]
            }
            persist(session.id)
        }
    }

    private func sortProjects() {
        projects.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func removeProject(_ project: Project) {
        for session in sessions(of: project.id, includingArchived: true) {
            running[session.id]?.cancel()
            sessions[session.id] = nil
            grid.remove(session.id)
        }
        projects.removeAll { $0.id == project.id }
        saveProjects()
        try? store.deleteSessions(of: project.id)
        if selectedSession == nil { selectedSessionID = nil }
    }

    /// The main folder's branch right now.
    func branch(of project: Project?) -> String? {
        project.flatMap { branches.branch(of: $0.path) }
    }

    private func watchBranches() {
        branches.watch(projects.flatMap(\.allPaths))
    }

    private func saveProjects() {
        do {
            try store.saveProjects(projects)
        } catch {
            alert = "Could not save projects: \(error.localizedDescription)"
        }
        watchBranches()
    }

    // MARK: Panes

    func setLayout(_ layout: PaneGrid.Layout) {
        grid.setLayout(layout)
    }

    func focusPane(_ index: Int) {
        grid.focus(index)
    }

    func open(_ sessionID: UUID, inPane index: Int) {
        guard sessions[sessionID] != nil else { return }
        grid.open(sessionID, inPane: index)
    }

    func clearPane(_ index: Int) {
        grid.clear(pane: index)
    }

    private static let gridKey = "paneGrid"

    private static func loadGrid() -> PaneGrid {
        guard let data = UserDefaults.standard.data(forKey: gridKey) else { return PaneGrid() }
        return (try? JSONDecoder().decode(PaneGrid.self, from: data)) ?? PaneGrid()
    }

    private static func saveGrid(_ grid: PaneGrid) {
        // A run on a copied data folder (debugging, snapshots) must not move the real panes.
        guard ProcessInfo.processInfo.environment["MOUNTAGENT_DATA_DIR"] == nil else { return }
        if let data = try? JSONEncoder().encode(grid) { UserDefaults.standard.set(data, forKey: gridKey) }
    }

    // MARK: Sessions

    @discardableResult
    func newSession(in project: Project, agent: AgentKind? = nil) -> ChatSession {
        let session = ChatSession(projectID: project.id, agent: agent ?? project.defaultAgent, access: AppSettings.defaultAccess)
        sessions[session.id] = session
        selectedSessionID = session.id
        persist(session.id)
        return session
    }

    func rename(_ sessionID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(sessionID) { $0.title = title }
        persist(sessionID)
    }

    func delete(_ sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        running[sessionID]?.cancel()
        SessionTerminals.shared.stop(sessionID)
        sessions[sessionID] = nil
        drafts[sessionID] = nil
        queued[sessionID] = nil
        try? store.delete(session)
        let wasFocused = selectedSessionID == sessionID
        grid.remove(sessionID)
        if wasFocused, let next = sessions(of: session.projectID).first(where: { grid.pane(showing: $0.id) == nil }) {
            selectedSessionID = next.id
        }
    }

    func update(_ sessionID: UUID, _ change: (inout ChatSession) -> Void) {
        guard var session = sessions[sessionID] else { return }
        change(&session)
        sessions[sessionID] = session
    }

    func setAgent(_ agent: AgentKind, for sessionID: UUID) {
        update(sessionID) { $0.agent = agent }
        persist(sessionID)
    }

    func setModel(_ model: String?, for sessionID: UUID) {
        update(sessionID) { $0.model = model }
        persist(sessionID)
    }

    /// Cursor model family of a session's current model.
    func cursorFamily(for session: ChatSession) -> ModelFamily? {
        let id = ModelCatalog.split(session.models[.cursor]).base
        return cursorFamilies.first { $0.id == id }
    }

    /// Picks a Cursor model family, keeping the session's effort and speed where the family has them.
    func setCursorFamily(_ family: ModelFamily, for sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        let current = cursorFamily(for: session)?.variant(for: session.models[.cursor])
        let id = family.modelID(effort: current?.effort, fast: current?.fast ?? false)
        update(sessionID) { $0.models[.cursor] = id }
        persist(sessionID)
    }

    /// Claude, Codex and Antigravity take effort as an option; for Cursor it selects the
    /// matching model variant.
    func setEffort(_ effort: String?, fast: Bool? = nil, for sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        switch session.agent {
        case .claude, .codex, .antigravity, .copilot, .gemini, .opencode:
            update(sessionID) { $0.efforts[session.agent] = effort }
        case .cursor:
            guard let family = cursorFamily(for: session) else { return }
            let current = family.variant(for: session.models[.cursor])
            let id = family.modelID(effort: effort, fast: fast ?? current?.fast ?? false)
            update(sessionID) { $0.models[.cursor] = id }
        }
        persist(sessionID)
    }

    /// Thumbs up (1) / down (-1); choosing the same again clears it.
    func rate(_ value: Int, item itemID: UUID, in sessionID: UUID) {
        update(sessionID) { session in
            if let index = session.items.firstIndex(where: { $0.id == itemID }) {
                session.items[index].rating = session.items[index].rating == value ? nil : value
            }
        }
        persist(sessionID)
    }

    /// Starts a new session from the transcript up to `itemID`.
    func fork(_ sessionID: UUID, through itemID: UUID) {
        guard let session = sessions[sessionID] else { return }
        let fork = session.forked(through: itemID)
        sessions[fork.id] = fork
        selectedSessionID = fork.id
        persist(fork.id)
    }

    func setAccess(_ access: AccessLevel, for sessionID: UUID) {
        update(sessionID) { $0.access = access }
        persist(sessionID)
    }

    /// Saves off the main thread (a long session is megabytes of JSON); `finishWrites`
    /// waits for it on quit.
    private func persist(_ sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        store.saveLater(session) { error in
            Task { @MainActor [weak self] in self?.alert = "Could not save the session: \(error.localizedDescription)" }
        }
    }

    func finishWrites() {
        store.finishWrites()
    }

    /// A turn's streamed events, applied together: one change to `sessions` (and one redraw
    /// of everything that shows it) per batch instead of per token.
    private final class TurnBuffer {
        var reducer: TranscriptReducer
        var pending: [AgentEvent] = []
        var scheduled = false

        init(agent: AgentKind) {
            reducer = TranscriptReducer(agent: agent)
        }

        /// Text and thinking deltas can wait a moment; anything else shows at once.
        static func canWait(_ event: AgentEvent) -> Bool {
            switch event {
            case .textDelta, .thinkingDelta, .textSnapshot, .reply, .rateLimit: true
            default: false
            }
        }
    }

    private static let streamInterval: Duration = .milliseconds(80)

    private func flush(_ buffer: TurnBuffer, into sessionID: UUID) {
        guard !buffer.pending.isEmpty else { return }
        let events = buffer.pending
        buffer.pending.removeAll()
        update(sessionID) { session in
            for event in events { buffer.reducer.apply(event, to: &session) }
        }
    }

    // MARK: Running

    /// `accessOverride` and `onFinish` serve retries of blocked Cursor calls.
    func send(
        _ text: String,
        attachments: [String],
        images: [URL] = [],
        in sessionID: UUID,
        accessOverride: AccessLevel? = nil,
        onFinish: (@MainActor () -> Void)? = nil
    ) {
        guard let session = sessions[sessionID], !isRunning(sessionID),
              let project = project(session.projectID)
        else { return }
        let agent = session.agent
        let missed = session.unseenItems(for: agent)
        var item = ChatItem(kind: .user, text: text, attachments: attachments)
        if !images.isEmpty { item.images = images.map(\.path) }
        let turnItem = item
        let prompt = PromptBuilder.prompt(text, attachments: attachments, missed: missed)

        let startBranch = session.worktreeBranch ?? branches.branch(of: project.path)
        let workRoot = workRoot(of: session, project: project)
        update(sessionID) { session in
            if session.items.isEmpty { session.title = PromptBuilder.title(from: text) }
            if let startBranch { session.branch = startBranch }
            if !missed.isEmpty {
                session.items.append(ChatItem(kind: .notice, agent: agent, text: "\(agent.displayName) was given the turns it missed."))
            }
            session.items.append(turnItem)
        }
        persist(sessionID)

        guard project.exists else {
            fail(sessionID, agent: agent, "The project folder \(project.path) no longer exists.")
            onFinish?()
            return
        }
        if let worktree = session.worktree, !FileManager.default.fileExists(atPath: worktree) {
            fail(sessionID, agent: agent, "This session's worktree \(worktree) no longer exists. Remove it from the session's menu to work in the main folder again.")
            onFinish?()
            return
        }
        let missing = project.missingPaths
        if !missing.isEmpty {
            update(sessionID) {
                $0.items.append(ChatItem(kind: .notice, agent: agent, text: "Skipped missing folders: \(missing.joined(separator: ", "))", isError: true))
            }
        }

        var request = AgentRunRequest(
            prompt: prompt,
            workingDirectory: workRoot,
            additionalDirectories: project.additionalURLs.filter { !missing.contains($0.path) },
            loadsAdditionalRules: project.loadsAdditionalRules,
            model: session.models[agent],
            effort: [.claude, .codex, .antigravity, .copilot].contains(agent) ? session.efforts[agent] : nil,
            access: accessOverride ?? session.access,
            resumeSessionID: session.agentSessionIDs[agent],
            sessionTitle: session.title
        )
        request.images = images
        let helperToken = applyServerAccess(of: project, to: &request)
        if agent == .copilot, let token = copilotToken() {
            request.environment[CopilotProvider.tokenVariable] = token
        }
        // The working folder as it is now, so this turn can be undone; then the agent starts.
        preparing.insert(sessionID)
        let root = workRoot
        let checkpointName = "\(sessionID.uuidString)/\(turnItem.id.uuidString)"
        Task {
            let checkpoint = await Task.detached(priority: .userInitiated) { () -> String? in
                guard GitCheckpoint.isRepository(root) else { return nil }
                return try? GitCheckpoint.create(in: root, name: checkpointName)
            }.value
            preparing.remove(sessionID)
            if let checkpoint {
                update(sessionID) { session in
                    if let index = session.items.lastIndex(where: { $0.id == turnItem.id }) { session.items[index].checkpoint = checkpoint }
                }
            }
            guard stoppedWhilePreparing.remove(sessionID) == nil else {
                update(sessionID) { $0.items.append(ChatItem(kind: .notice, agent: agent, text: "Stopped before \(agent.displayName) started.")) }
                persist(sessionID)
                onFinish?()
                return
            }
            startTurn(request, agent: agent, project: project, in: sessionID, helperToken: helperToken, onFinish: onFinish)
        }
    }

    private func startTurn(_ request: AgentRunRequest, agent: AgentKind, project: Project, in sessionID: UUID, helperToken: String?, onFinish: (@MainActor () -> Void)?) {
        let run: AgentRun
        do {
            run = try runner.start(request, with: AgentProviders.provider(for: agent))
        } catch {
            if let helperToken { helperGrants[helperToken] = nil }
            fail(sessionID, agent: agent, error.localizedDescription)
            onFinish?()
            return
        }
        running[sessionID] = run

        Task {
            let buffer = TurnBuffer(agent: agent)
            var failure: String?
            for await event in run.events {
                switch event {
                case .failure(let message) where message.contains("No conversation found")
                    || (message.localizedCaseInsensitiveContains("session") && message.localizedCaseInsensitiveContains("not found")):
                    // The CLI no longer has this session; start fresh next time.
                    update(sessionID) { $0.agentSessionIDs[agent] = nil }
                case .rateLimit(let info):
                    setPlanUsage(planUsage?.updated(with: info) ?? PlanUsage.from(info))
                case .failure(let message):
                    failure = message
                case .permissionRequest(let request):
                    pendingPermissions[request.id] = request
                    pendingCounts[sessionID, default: 0] += 1
                    if !NSApp.isActive, let session = sessions[sessionID] {
                        Notifier.permissionNeeded(session: session, request: request)
                    }
                default:
                    break
                }
                buffer.pending.append(event)
                if !TurnBuffer.canWait(event) {
                    flush(buffer, into: sessionID)
                } else if !buffer.scheduled {
                    buffer.scheduled = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: Self.streamInterval)
                        buffer.scheduled = false
                        self?.flush(buffer, into: sessionID)
                    }
                }
            }
            flush(buffer, into: sessionID)
            let reducer = buffer.reducer
            running[sessionID] = nil
            if let helperToken { helperGrants[helperToken] = nil }
            // Unanswered questions expired with the turn.
            pendingCounts[sessionID] = nil
            pendingPermissions = pendingPermissions.filter { id, _ in sessions[sessionID]?.items.contains { $0.toolCallID == id } != true }
            onFinish?()
            lastResults[sessionID] = reducer.lastResult
            if let result = reducer.lastResult {
                ledger.record(result, agent: agent, project: project.id)
                try? store.save(ledger, named: "usage")
            }
            if agent == .cursor { refreshCursorUsage() }
            if agent == .codex { refreshCodexUsage() }
            if agent == .claude || agent == .codex { refreshLocalUsage() }
            refreshDirty()
            if agent == .copilot { refreshCopilotUsage() }
            // Agents may switch branches during a turn; remember where this session ended up.
            // A worktree session stays on its own branch; the main folder's may have moved.
            let worktreeBranch = sessions[sessionID]?.worktreeBranch
            if worktreeBranch == nil { branches.refresh(project.path) }
            let endBranch = worktreeBranch ?? branches.branch(of: project.path)
            update(sessionID) { session in
                session.seenCounts[agent] = session.items.count
                if let endBranch { session.branch = endBranch }
            }
            persist(sessionID)
            if NSApp.isActive == false, let session = sessions[sessionID] {
                Notifier.turnFinished(session: session, result: reducer.lastResult, failure: failure)
            }
            if let next = queued.removeValue(forKey: sessionID) {
                send(next.text, attachments: next.attachments, images: next.images, in: sessionID)
            }
        }
    }

    func stop(_ sessionID: UUID) {
        if preparing.contains(sessionID) { stoppedWhilePreparing.insert(sessionID) }
        running[sessionID]?.cancel()
    }

    /// Where the session's agents work: its own worktree, or the project's main folder.
    func workRoot(of session: ChatSession, project: Project) -> URL {
        session.worktree.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? project.url
    }

    /// A session with a worktree and branch of its own, made from the main folder's HEAD
    /// (copying the files can take a moment, so it happens off the main thread).
    func newSessionInWorktree(in project: Project) {
        let repository = project.url
        let id = UUID()
        Task {
            do {
                let created = try await Task.detached { () -> GitWorktree.Created in
                    guard GitCheckpoint.isRepository(repository) else {
                        throw NSError(domain: "Worktree", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(repository.lastPathComponent) isn't the top folder of a git repository."])
                    }
                    return try GitWorktree.create(in: repository, title: "", id: id)
                }.value
                var session = newSession(in: project)
                update(session.id) {
                    $0.worktree = created.path.path
                    $0.worktreeBranch = created.branch
                    $0.branch = created.branch
                }
                session = sessions[session.id] ?? session
                persist(session.id)
            } catch {
                alert = "Couldn't make a worktree: \(error.localizedDescription)"
            }
        }
    }

    /// Removes the session's worktree after asking (the branch stays); the session then
    /// works in the main folder, on fresh CLI sessions.
    func removeWorktree(of sessionID: UUID) {
        guard !isRunning(sessionID), let session = sessions[sessionID], let path = session.worktree,
              let project = project(session.projectID)
        else { return }
        let question = NSAlert()
        question.messageText = "Remove this session's worktree?"
        question.informativeText = "\(path) is deleted; its branch \(session.worktreeBranch ?? "") stays, so committed work can still be merged. The session then works in the main folder."
        question.addButton(withTitle: "Remove")
        question.addButton(withTitle: "Cancel")
        guard question.runModal() == .alertFirstButtonReturn else { return }
        let repository = project.url
        let folder = URL(fileURLWithPath: path)
        Task {
            var removed = (try? await Task.detached { try GitWorktree.remove(folder, from: repository) }.value) != nil
            if !removed {
                let dirty = NSAlert()
                dirty.alertStyle = .warning
                dirty.messageText = "The worktree has changes that aren't committed"
                dirty.informativeText = "Removing it anyway discards them. Commit them on \(session.worktreeBranch ?? "its branch") first to keep them."
                dirty.addButton(withTitle: "Remove Anyway")
                dirty.addButton(withTitle: "Cancel")
                guard dirty.runModal() == .alertFirstButtonReturn else { return }
                do {
                    try await Task.detached { try GitWorktree.remove(folder, from: repository, force: true) }.value
                    removed = true
                } catch {
                    alert = "Couldn't remove the worktree: \(error.localizedDescription)"
                }
            }
            guard removed else { return }
            update(sessionID) {
                $0.worktree = nil
                $0.worktreeBranch = nil
                $0.agentSessionIDs = [:]
                $0.seenCounts = [:]
                $0.items.append(ChatItem(kind: .notice, text: "The worktree was removed; this session now works in the main folder."))
            }
            persist(sessionID)
        }
    }

    /// The checkpoint taken before the turn that `itemID` belongs to.
    func checkpoint(beforeTurnOf itemID: UUID, in sessionID: UUID) -> String? {
        guard let items = sessions[sessionID]?.items, let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return items[...index].last { $0.kind == .user }?.checkpoint
    }

    /// Puts the main folder's files back as they were before the turn of `itemID`, after
    /// asking; the state just before is kept, and a notice offers to bring it back.
    func revertTurn(of itemID: UUID, in sessionID: UUID) {
        guard !isRunning(sessionID), let session = sessions[sessionID], let project = project(session.projectID),
              let checkpoint = checkpoint(beforeTurnOf: itemID, in: sessionID)
        else { return }
        let root = workRoot(of: session, project: project)
        let later = session.items.drop { $0.id != itemID }.dropFirst().contains { $0.kind == .user }
        Task {
            let changes = await Task.detached { (try? GitCheckpoint.changes(in: root, since: checkpoint)) ?? [] }.value
            guard !changes.isEmpty else {
                alert = "The files are as they were before this turn; nothing to revert."
                return
            }
            let question = NSAlert()
            question.alertStyle = .warning
            question.messageText = "Revert \(changes.count) file\(changes.count == 1 ? "" : "s") to before this turn?"
            let listed = changes.prefix(8).map { "\($0.status)  \($0.path)" }.joined(separator: "\n") + (changes.count > 8 ? "\n…" : "")
            question.informativeText = listed + "\n\n" + (later ? "Changes from the turns after it are undone too. " : "")
                + "Commits made since stay. The files as they are now are kept, so this can be undone."
            question.addButton(withTitle: "Revert")
            question.addButton(withTitle: "Cancel")
            guard question.runModal() == .alertFirstButtonReturn else { return }
            do {
                let name = "\(sessionID.uuidString)/revert-\(UUID().uuidString)"
                let undo = try await Task.detached { try GitCheckpoint.restore(in: root, to: checkpoint, undoName: name) }.value
                var notice = ChatItem(kind: .notice, text: "Reverted \(changes.count) file\(changes.count == 1 ? "" : "s") to before this turn.")
                notice.checkpoint = undo
                update(sessionID) { $0.items.append(notice) }
                persist(sessionID)
            } catch {
                alert = "Couldn't revert: \(error.localizedDescription)"
            }
        }
    }

    /// Brings back the files a revert replaced (the notice's checkpoint).
    func undoRevert(_ itemID: UUID, in sessionID: UUID) {
        guard !isRunning(sessionID), let session = sessions[sessionID], let project = project(session.projectID),
              let undo = session.items.first(where: { $0.id == itemID })?.checkpoint
        else { return }
        let root = workRoot(of: session, project: project)
        Task {
            do {
                let name = "\(sessionID.uuidString)/redo-\(UUID().uuidString)"
                try await Task.detached { _ = try GitCheckpoint.restore(in: root, to: undo, undoName: name) }.value
                update(sessionID) { session in
                    if let index = session.items.firstIndex(where: { $0.id == itemID }) {
                        session.items[index].checkpoint = nil
                        session.items[index].text += " Undone."
                    }
                }
                persist(sessionID)
            } catch {
                alert = "Couldn't undo the revert: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Permissions

    /// Answers a request Claude is waiting on.
    func answer(_ reply: PermissionReply, item itemID: UUID, in sessionID: UUID) {
        guard let item = sessions[sessionID]?.items.first(where: { $0.id == itemID }),
              item.permissionState == .pending,
              let requestID = item.toolCallID,
              let request = pendingPermissions.removeValue(forKey: requestID),
              let run = running[sessionID]
        else { return }
        pendingCounts[sessionID] = max(0, pendingCounts[sessionID, default: 1] - 1)
        let state: PermissionState = run.respond(reply, to: request)
            ? (reply == .deny ? .denied : reply == .allowAlways ? .alwaysAllowed : .allowed)
            : .expired
        setPermissionState(state, item: itemID, in: sessionID)
    }

    /// Lets a call Cursor refused through and asks it to try again. "Once" adds the rule to
    /// `.cursor/cli.json` only for the retry; without a known rule the retry runs with full access.
    func retryBlocked(item itemID: UUID, in sessionID: UUID, always: Bool, confirmsFullAccess: Bool = true) {
        guard let session = sessions[sessionID], running[sessionID] == nil,
              let project = project(session.projectID),
              let item = session.items.first(where: { $0.id == itemID }), item.permissionState == .blocked
        else { return }
        if item.permissionRule == nil, confirmsFullAccess {
            // Without a rule for the step, the only way through is a whole turn with full access.
            let question = NSAlert()
            question.alertStyle = .warning
            question.messageText = "Retry with full access?"
            question.informativeText = "\(session.agent.displayName) didn't name a rule that would allow just this step, so the retry runs the whole next turn with full access: every command and file change goes through without asking, not only this one."
            question.addButton(withTitle: "Retry with Full Access")
            question.addButton(withTitle: "Cancel")
            guard question.runModal() == .alertFirstButtonReturn else { return }
        }
        setPermissionState(always ? .retriedAlways : .retriedOnce, item: itemID, in: sessionID)

        let what = "\(item.toolName ?? "tool") \(item.text)"
        guard let rule = item.permissionRule else {
            send("I approved the blocked step (\(what)) for this one retry. Run it again and continue.",
                 attachments: [], in: sessionID, accessOverride: .fullAccess)
            return
        }
        var added = false
        do {
            added = try CursorPermissions.allow(rule, in: project.url)
        } catch {
            alert = "Could not update \(CursorPermissions.relativePath): \(error.localizedDescription)"
            return
        }
        let revokeAfter = added && !always
        send("I approved \(rule)\(always ? "" : " for this retry"). Run the blocked step (\(what)) again and continue.",
             attachments: [], in: sessionID) {
            if revokeAfter { try? CursorPermissions.revoke(rule, in: project.url) }
        }
    }

    func dismissBlocked(item itemID: UUID, in sessionID: UUID) {
        setPermissionState(.dismissed, item: itemID, in: sessionID)
    }

    private func setPermissionState(_ state: PermissionState, item itemID: UUID, in sessionID: UUID) {
        update(sessionID) { session in
            if let index = session.items.firstIndex(where: { $0.id == itemID }) {
                session.items[index].permissionState = state
            }
        }
        persist(sessionID)
    }

    private func fail(_ sessionID: UUID, agent: AgentKind, _ message: String) {
        update(sessionID) { $0.items.append(ChatItem(kind: .notice, agent: agent, text: message, isError: true)) }
        persist(sessionID)
    }

    func stopAll() {
        running.values.forEach { $0.cancel() }
    }

    /// On quit: stops the agents and keeps what each turn had done, marked as cut short, so
    /// the session reopens with the partial reply and no row left spinning.
    func interruptAll() {
        for (sessionID, run) in running {
            run.cancel()
            guard let agent = sessions[sessionID]?.agent else { continue }
            update(sessionID) { session in
                for index in session.items.indices where session.items[index].toolStatus == .running {
                    session.items[index].toolStatus = .failed
                }
                session.items.append(ChatItem(kind: .notice, agent: agent, text: "Stopped: Mountagent Desk quit while \(agent.displayName) was working. What it did so far is kept.", isError: true))
            }
            persist(sessionID)
        }
    }

    /// Sends now, or, while the agent is busy, when its turn ends (one message waits; a new
    /// one is added to it).
    func submit(_ text: String, attachments: [String], images: [URL], in sessionID: UUID) {
        guard isRunning(sessionID) else {
            send(text, attachments: attachments, images: images, in: sessionID)
            return
        }
        if var waiting = queued[sessionID] {
            waiting.text += "\n\n" + text
            waiting.attachments += attachments
            waiting.images += images
            queued[sessionID] = waiting
        } else {
            queued[sessionID] = QueuedMessage(text: text, attachments: attachments, images: images)
        }
    }

    func cancelQueued(in sessionID: UUID) -> QueuedMessage? {
        queued.removeValue(forKey: sessionID)
    }

    /// Asks before deleting: the session's file goes to the Trash.
    func confirmDelete(_ sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        let question = NSAlert()
        question.messageText = "Delete \u{201C}\(session.title)\u{201D}?"
        question.informativeText = "The conversation is moved to the Trash; the agent's own CLI history is kept."
        question.addButton(withTitle: "Delete")
        question.addButton(withTitle: "Cancel")
        question.buttons.first?.hasDestructiveAction = true
        if question.runModal() == .alertFirstButtonReturn { delete(sessionID) }
    }

    /// Asks before removing: the project's folders stay; its sessions go to the Trash.
    func confirmRemove(_ project: Project) {
        let count = sessions(of: project.id, includingArchived: true).count
        let question = NSAlert()
        question.messageText = "Remove \u{201C}\(project.name)\u{201D} from Mountagent Desk?"
        question.informativeText = "Its folders aren't touched. Its \(count) session\(count == 1 ? "" : "s") \(count == 1 ? "is" : "are") moved to the Trash."
        question.addButton(withTitle: "Remove")
        question.addButton(withTitle: "Cancel")
        question.buttons.first?.hasDestructiveAction = true
        if question.runModal() == .alertFirstButtonReturn { removeProject(project) }
    }

    // MARK: Git accounts

    func gitAccount(_ id: UUID?) -> GitAccount? {
        gitAccounts.first { $0.id == id }
    }

    func saveGitAccount(_ account: GitAccount) {
        var accounts = gitAccounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        saveGitAccounts(accounts)
        // Projects using this account get the edited name, email or key too.
        for project in projects where project.gitAccountID == account.id {
            applyGitAccount(account.id, to: project)
        }
    }

    func deleteGitAccount(_ account: GitAccount) {
        saveGitAccounts(gitAccounts.filter { $0.id != account.id })
        for project in projects where project.gitAccountID == account.id {
            var updated = project
            updated.gitAccountID = nil
            updateProject(updated)
            applyGitAccount(nil, to: updated)
        }
    }

    private func saveGitAccounts(_ accounts: [GitAccount]) {
        gitAccounts = accounts
        do {
            try store.save(accounts, named: "git-accounts")
        } catch {
            alert = "Could not save git accounts: \(error.localizedDescription)"
        }
    }

    /// Writes the account into `.git/config` of every repository among the project's folders;
    /// `nil` removes Mountagent Desk's settings so the global config applies again.
    /// Writes the account into each folder's `.git/config` (a few git commands per folder,
    /// so off the main thread).
    func applyGitAccount(_ accountID: UUID?, to project: Project) {
        let account = gitAccount(accountID)
        let paths = project.allPaths
        Task {
            let failures = await Task.detached { () -> [String] in
                var failures: [String] = []
                for path in paths {
                    let repository = GitRepository(root: URL(fileURLWithPath: path))
                    guard repository.isRepository else { continue }
                    if let account {
                        do {
                            try repository.apply(account)
                        } catch {
                            failures.append((path as NSString).lastPathComponent)
                        }
                    } else {
                        repository.clearAccount()
                    }
                }
                return failures
            }.value
            if !failures.isEmpty {
                alert = "Couldn't set the git account in: \(failures.joined(separator: ", "))"
            }
        }
    }

    // MARK: Servers

    /// Where the app keeps its data (and the agents' server log).
    var dataRoot: URL { store.root }

    /// Hands ssh a saved server password (see `ServerPasswords`).
    /// ssh's askpass for the user's own terminals and connection tests: the app's executable
    /// itself (`Launcher` sees the askpass variable), not the script in the data folder,
    /// which any agent running as the user could rewrite.
    var askpass: URL { ServerHelper.askpassExecutable }

    func server(_ id: UUID) -> Server? {
        servers.first { $0.id == id }
    }

    /// The project's servers, by name.
    func servers(of project: Project) -> [Server] {
        servers
            .filter { project.serverIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func saveServer(_ server: Server) {
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        saveServers(updated)
    }

    func deleteServer(_ server: Server) {
        ServerPasswords.delete(account: server.passwordAccount)
        saveServers(servers.filter { $0.id != server.id })
        for project in projects where project.serverIDs.contains(server.id) {
            setServer(server.id, linked: false, to: project)
        }
    }

    func setServer(_ serverID: UUID, linked: Bool, to project: Project) {
        guard var updated = self.project(project.id) else { return }
        updated.serverIDs.removeAll { $0 == serverID }
        if linked { updated.serverIDs.append(serverID) }
        updateProject(updated)
    }

    /// Lets agents read the server through `mountagent-server`, or stops them.
    func setReadAccess(_ on: Bool, for serverID: UUID) {
        guard var server = server(serverID) else { return }
        server.aiReadAccess = on
        saveServer(server)
    }

    private func saveServers(_ list: [Server]) {
        servers = list
        do {
            try ServerPasswords.saveAgentAccess(Set(list.filter(\.aiReadAccess).map(\.id)), root: store.root)
            try ServerPasswords.saveAgentSudoUsers(Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.agentSudoUsers) }), root: store.root)
            try store.save(list, named: "servers")
        } catch {
            alert = "Could not save servers: \(error.localizedDescription)"
        }
    }

    /// Agent access lives in the keychain; servers.json only mirrors it, so editing the file
    /// gives no agent access. The first launch after the move takes the file's flags once.
    private func applyAgentAccessFromKeychain() {
        // Sudo users only ever come from the keychain: none until the user sets some.
        let sudo = ServerPasswords.agentSudoUsers(root: store.root)
        for index in servers.indices { servers[index].agentSudoUsers = sudo[servers[index].id] ?? [] }
        if let granted = ServerPasswords.agentAccess(root: store.root) {
            for index in servers.indices { servers[index].aiReadAccess = granted.contains(servers[index].id) }
        } else {
            try? ServerPasswords.saveAgentAccess(Set(servers.filter(\.aiReadAccess).map(\.id)), root: store.root)
        }
    }

    func login(for server: Server) -> SSHLogin {
        server.login(with: serverCredentials)
    }

    func credential(_ id: UUID?) -> ServerCredential? {
        serverCredentials.first { $0.id == id }
    }

    func saveCredential(_ credential: ServerCredential) {
        var updated = serverCredentials
        if let index = updated.firstIndex(where: { $0.id == credential.id }) {
            updated[index] = credential
        } else {
            updated.append(credential)
        }
        saveCredentials(updated)
    }

    /// Removes the credential and its keychain password; servers using it fall back to the SSH config.
    func deleteCredential(_ credential: ServerCredential) {
        ServerPasswords.delete(account: credential.passwordAccount)
        saveCredentials(serverCredentials.filter { $0.id != credential.id })
        saveServers(servers.map { server in
            var server = server
            if server.credentialID == credential.id { server.credentialID = nil }
            return server
        })
    }

    private func saveCredentials(_ list: [ServerCredential]) {
        serverCredentials = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            try store.save(serverCredentials, named: "server-credentials")
        } catch {
            alert = "Could not save credentials: \(error.localizedDescription)"
        }
    }

    func history(of serverID: UUID) -> ServerCommandHistory {
        serverHistories[serverID.uuidString] ?? ServerCommandHistory()
    }

    func updateHistory(of serverID: UUID, _ change: (inout ServerCommandHistory) -> Void) {
        var history = history(of: serverID)
        change(&history)
        serverHistories[serverID.uuidString] = history
        try? store.save(serverHistories, named: "server-history")
    }

    /// Adds the server's own shell history (`~/.bash_history`, `~/.zsh_history`); returns
    /// how many commands it held, or why it couldn't be read.
    func importShellHistory(of server: Server) async -> Result<Int, Error> {
        let login = login(for: server)
        let askpass = askpass
        let result = await Task.detached { () -> Result<String, Error> in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = login.commandArguments(ServerCommandHistory.readCommand)
            process.environment = ProcessInfo.processInfo.environment.merging(login.askpassEnvironment(askpass: askpass)) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return .failure(error)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let line = errorText.split(separator: "\n").last.map(String.init) ?? "ssh exited with status \(process.terminationStatus)."
                return .failure(NSError(domain: "ssh", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: line]))
            }
            return .success(String(decoding: data, as: UTF8.self))
        }.value
        switch result {
        case .success(let text):
            let commands = ServerCommandHistory.parseShellHistory(text)
            updateHistory(of: server.id) { $0.merge(imported: commands) }
            return .success(commands.count)
        case .failure(let error):
            return .failure(error)
        }
    }

    func saveSnippets(_ snippets: [ServerSnippet]) {
        serverSnippets = snippets
        do {
            try store.save(snippets, named: "server-snippets")
        } catch {
            alert = "Could not save commands: \(error.localizedDescription)"
        }
    }

    /// Keeps agents off the project's servers, except read-only through `mountagent-server`
    /// on the ones the user opened to them. Returns the run's helper token, revoked when the
    /// run ends.
    private func applyServerAccess(of project: Project, to request: inout AgentRunRequest) -> String? {
        request.linksServers = !servers(of: project).isEmpty
        let readable = ServerHelper.readable(in: project, servers: servers)
        guard !readable.isEmpty, serverHelperDirectory != nil, helperListener != nil else { return nil }
        // Written again before each run: an agent that changed the script can't hand its
        // version to the next one, which is allowed to run it without asking.
        guard let executable = Bundle.main.executablePath,
              let directory = try? ServerHelper.installWrapper(executable: executable, in: store.root)
        else { return nil }
        let token = UUID().uuidString + UUID().uuidString
        helperGrants[token] = project.id
        request.environment[ServerBroker.tokenVariable] = token
        request.readsServers = true
        request.environment["PATH"] = directory.path + ":" + (ExecutableLocator.environment["PATH"] ?? "")
        request.prompt = "<mountagent>\(ServerHelper.note(for: readable))</mountagent>\n\n" + request.prompt
        return token
    }

    /// What a run's helper asked for, decided here, where the run's project and the agent
    /// access are known for sure.
    private enum HelperJob: Sendable {
        case reply(ServerBroker.Reply)
        case run(arguments: [String], password: String?)
    }

    /// Serves `mountagent-server`: decisions on the main thread, ssh on the listener's.
    private func startHelperListener() {
        let listener = ServerBroker.Listener(root: store.root) { [weak self] request in
            let job = DispatchQueue.main.sync {
                MainActor.assumeIsolated { self?.helperJob(for: request) }
            } ?? .reply(.refused("Mountagent Desk is closing."))
            switch job {
            case .reply(let reply): return reply
            case .run(let arguments, let password): return ServerRun.ssh(arguments, password: password)
            }
        }
        do {
            try listener.start()
            helperListener = listener
        } catch {
            // Agents just don't get `mountagent-server` (applyServerAccess checks).
        }
    }

    func stopHelperListener() {
        helperListener?.stop()
        helperListener = nil
    }

    private func helperJob(for request: ServerBroker.Request) -> HelperJob {
        let project = helperGrants[request.token].flatMap { self.project($0) }
        let root = store.root
        let decision = ServerHelper.decide(request, project: project, servers: servers) { server, command, outcome in
            ServerHelper.audit(root: root, project: project?.name ?? "?", server: server.name, command: command, outcome: outcome)
        }
        switch decision {
        case .reply(let reply):
            return .reply(reply)
        case .run(let server, let command):
            let login = login(for: server)
            let alias = SSHConfigImport.entries().first { $0.alias == server.host }
            return .run(arguments: login.agentArguments(command, config: alias), password: login.savedPassword())
        }
    }

    // MARK: Accounts

    func account(_ kind: AgentKind) -> AgentAccount? {
        accounts[kind]
    }

    /// Reads Claude's plan limits with `claude -p /usage` (local, free).
    func refreshPlanUsage() {
        let probe = AccountProbe(runner: runner)
        Task.detached(priority: .utility) {
            guard let usage = probe.claudePlanUsage() else { return }
            await MainActor.run { self.setPlanUsage(usage) }
        }
        refreshCodexUsage()
        refreshCopilotUsage()
        refreshLocalUsage()
    }

    /// Re-reads the logs that changed since the last scan, off the main thread. Prices the
    /// user adds or corrects go in `model-prices.json` in the data folder.
    func refreshLocalUsage() {
        guard !scanningLocalUsage else { return }
        scanningLocalUsage = true
        let prices = ModelPrices.builtIn.merging(store.load([String: ModelPrices.Price].self, named: "model-prices") ?? [:])
        let saved = store.load(LocalUsage.Cache.self, named: "local-usage-cache") ?? LocalUsage.Cache()
        Task.detached(priority: .utility) {
            var cache = saved
            let entries = LocalUsage.scan(prices: prices, cache: &cache)
            await MainActor.run {
                self.localUsage = entries
                self.scanningLocalUsage = false
                try? self.store.save(cache, named: "local-usage-cache")
            }
        }
    }

    func refreshCodexUsage() {
        guard enabledAgents.contains(.codex) else { return }
        Task.detached(priority: .utility) {
            let usage = CodexLimits.latest()
            await MainActor.run { self.codexUsage = usage }
        }
    }

    func refreshCopilotUsage() {
        guard enabledAgents.contains(.copilot), let token = copilotToken() else { return }
        Task {
            if let result = await CopilotLimits.fetch(token: token) { copilotUsage = result }
        }
    }

    var showsCursorUsage: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.cursorUsageKey)
    }

    /// Turns Cursor usage on (the keychain prompt follows) or off.
    func setShowsCursorUsage(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: AppSettings.cursorUsageKey)
        if on {
            refreshCursorUsage(userInitiated: true)
        } else {
            cursorToken = nil
            cursorUsage = nil
            cursorUsageProblem = nil
            try? store.save(Optional<CursorUsage>.none, named: "cursor-usage")
        }
    }

    /// Cursor's access token, read from the keychain once and kept in memory, so macOS
    /// asks at most once per launch instead of on every refresh.
    private var cursorToken: String?
    private var cursorFetchInFlight = false
    /// Set when the keychain or Cursor refused; background refreshes then wait for the user.
    private var cursorWaitsForUser = false

    /// Reads Cursor's current-cycle usage with the CLI's own token. When Cursor rejects the
    /// token, `cursor-agent status` refreshes it and the keychain is read once more.
    /// `userInitiated` refreshes also retry after a refusal; timer refreshes don't, so a
    /// denied keychain prompt doesn't come back every five minutes.
    func refreshCursorUsage(userInitiated: Bool = false) {
        guard showsCursorUsage, !cursorFetchInFlight else { return }
        if cursorWaitsForUser, !userInitiated { return }
        #if DEBUG
        // UI checks render saved usage without touching the keychain.
        if ProcessInfo.processInfo.environment["MOUNTAGENT_SKIP_CURSOR_FETCH"] != nil { return }
        #endif
        cursorFetchInFlight = true
        let runner = runner
        let cached = cursorToken
        Task.detached(priority: .utility) {
            let client = CursorUsageClient()
            var token = cached ?? CursorCredentials.accessToken()
            var outcome: Result<CursorUsage, Error> = .failure(CursorUsageError.unauthorized)
            if let current = token {
                do {
                    outcome = .success(try await client.fetch(token: current))
                } catch CursorUsageError.unauthorized {
                    _ = try? runner.capture(.cursor, arguments: ["status"], timeout: 30)
                    token = CursorCredentials.accessToken()
                    if let fresh = token, fresh != current {
                        do {
                            outcome = .success(try await client.fetch(token: fresh))
                        } catch {
                            outcome = .failure(error)
                        }
                    }
                } catch {
                    outcome = .failure(error)
                }
            }
            let finalToken = token
            await MainActor.run {
                self.cursorFetchInFlight = false
                switch outcome {
                case .success(let usage):
                    self.cursorWaitsForUser = false
                    self.cursorToken = finalToken
                    self.cursorUsage = usage
                    self.cursorUsageProblem = nil
                    try? self.store.save(usage, named: "cursor-usage")
                case .failure(CursorUsageError.unauthorized):
                    self.cursorWaitsForUser = true
                    self.cursorToken = nil
                    self.cursorUsageProblem = "Couldn't read Cursor's sign-in. Allow Mountagent Desk in the keychain prompt, or sign in to Cursor again."
                case .failure:
                    self.cursorToken = finalToken
                    self.cursorUsageProblem = "Cursor's usage service didn't answer. It's an internal API and may have changed."
                }
            }
        }
    }

    private func setPlanUsage(_ usage: PlanUsage) {
        planUsage = usage
        try? store.save(usage, named: "plan-usage")
    }

    /// Re-reads each CLI's install and sign-in state.
    func refreshAccounts() {
        checkingAccounts = true
        let probe = AccountProbe(runner: runner, copilotLogin: copilotAccount)
        // Only what's switched on: probing runs each CLI.
        let agents = agentChoices
        Task.detached(priority: .utility) {
            var found: [AgentKind: AgentAccount] = [:]
            for kind in agents {
                found[kind] = probe.probe(kind)
            }
            await MainActor.run {
                self.accounts = found
                self.checkingAccounts = false
            }
        }
    }

    /// Installs the CLI if needed, then signs in through the browser.
    func setUp(_ kind: AgentKind, from host: SetupTask.Host = .main) {
        let account = accounts[kind]
        if account?.isInstalled == true {
            setupTask = SetupTask(kind: kind, title: "Sign in to \(kind.displayName)", command: AgentSetup.loginCommand(for: kind, executable: account?.executable), host: host, hint: AgentSetup.loginHint(for: kind), signIn: AgentSetup.signInFlow(for: kind))
        } else {
            let command = AgentSetup.installCommand(for: kind) + " && " + AgentSetup.loginCommand(for: kind, executable: nil)
            setupTask = SetupTask(kind: kind, title: "Install \(kind.displayName)", command: command, host: host, hint: AgentSetup.loginHint(for: kind), signIn: AgentSetup.signInFlow(for: kind))
        }
    }

    func signOut(_ kind: AgentKind, from host: SetupTask.Host = .main) {
        guard let command = AgentSetup.logoutCommand(for: kind, executable: accounts[kind]?.executable) else { return }
        setupTask = SetupTask(kind: kind, title: "Sign out of \(kind.displayName)", command: command, host: host)
    }

    func update(_ kind: AgentKind, from host: SetupTask.Host = .main) {
        setupTask = SetupTask(kind: kind, title: "Update \(kind.displayName)", command: AgentSetup.updateCommand(for: kind, executable: accounts[kind]?.executable), host: host)
    }

    /// Some switched-on agent is missing or signed out.
    var anyAgentNeedsSetup: Bool { agentChoices.contains(where: needsSetup) }

    /// True when the agent is missing or signed out (only once the check has run).
    func needsSetup(_ kind: AgentKind) -> Bool {
        guard enabledAgents.contains(kind), let account = accounts[kind] else { return false }
        return !account.isInstalled || !account.loggedIn
    }

    func setupFinished() {
        setupTask = nil
        refreshAccounts()
        refreshPlanUsage()
        refreshCursorUsage()
        refreshCursorModels()
        refreshCodexModels()
        refreshCopilotModels()
        refreshOpenCodeModels()
    }

    // MARK: Models

    func refreshCursorModels() {
        let runner = runner
        Task.detached(priority: .utility) {
            guard let output = try? runner.capture(.cursor, arguments: ["models"]) else { return }
            let models = CursorProvider.parseModels(output)
            guard models.count > 1 else { return }
            await MainActor.run { self.cursorModels = models }
        }
    }

    /// The `gh` account Copilot runs as; nil leaves it to `copilot login`.
    var copilotAccount: String? {
        UserDefaults.standard.string(forKey: AppSettings.copilotAccountKey)
    }

    func setCopilotAccount(_ login: String?) {
        UserDefaults.standard.set(login, forKey: AppSettings.copilotAccountKey)
        prefetchGitHubToken()
        refreshAccounts()
    }

    /// A token made for Copilot alone (fine-grained, "Copilot Requests"), in the keychain.
    /// Without one Copilot gets the gh sign-in's token, which can also push to repositories.
    static let copilotTokenAccount = "copilot-token"
    private(set) var hasCopilotToken = ServerPasswords.secret(account: AppModel.copilotTokenAccount) != nil
    /// gh's token per account, read off the main thread (`gh auth token` takes a moment).
    @ObservationIgnored private var githubTokens: [String: String] = [:]

    func saveCopilotToken(_ token: String?) {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            ServerPasswords.delete(account: Self.copilotTokenAccount)
        } else {
            do {
                try ServerPasswords.save(value, account: Self.copilotTokenAccount)
            } catch {
                alert = "Couldn't save the token in Keychain: \(error.localizedDescription)"
            }
        }
        hasCopilotToken = ServerPasswords.secret(account: Self.copilotTokenAccount) != nil
    }

    func prefetchGitHubToken() {
        guard let login = copilotAccount, githubTokens[login] == nil else { return }
        Task.detached(priority: .utility) {
            guard let token = GitHubCLI.token(for: login) else { return }
            await MainActor.run { self.githubTokens[login] = token }
        }
    }

    private func copilotToken() -> String? {
        if let own = ServerPasswords.secret(account: Self.copilotTokenAccount) { return own }
        guard let login = copilotAccount else { return nil }
        if let cached = githubTokens[login] { return cached }
        // Only when a send comes before the prefetch finished.
        let token = GitHubCLI.token(for: login)
        githubTokens[login] = token
        return token
    }

    func refreshCopilotModels() {
        guard enabledAgents.contains(.copilot) else { return }
        let runner = runner
        Task.detached(priority: .utility) {
            guard let output = try? runner.capture(.copilot, arguments: ["help", "config"], timeout: 30) else { return }
            let models = CopilotProvider.parseModels(output)
            guard models.count > 1 else { return }
            await MainActor.run { self.copilotModels = models }
        }
    }

    func refreshOpenCodeModels() {
        guard enabledAgents.contains(.opencode) else { return }
        let runner = runner
        Task.detached(priority: .utility) {
            guard let output = try? runner.capture(.opencode, arguments: ["models"], timeout: 30) else { return }
            let models = OpenCodeProvider.parseModels(output)
            guard models.count > 1 else { return }
            await MainActor.run { self.openCodeModels = models }
        }
    }

    func refreshCodexModels() {
        guard enabledAgents.contains(.codex) else { return }
        let runner = runner
        Task.detached(priority: .utility) {
            guard let output = try? runner.capture(.codex, arguments: ["debug", "models"], timeout: 30) else { return }
            let models = CodexProvider.parseModels(output)
            guard !models.isEmpty else { return }
            await MainActor.run { self.codexModels = models }
        }
    }
}
