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
        set { grid.open(newValue) }
    }
    /// Project whose rules and skills sheet is open.
    var contextProject: Project?
    /// Project whose folders sheet is open.
    var foldersProject: Project?
    private(set) var running: [UUID: AgentRun] = [:]
    /// Permission requests an agent is waiting on, by request id.
    private var pendingPermissions: [String: PermissionRequest] = [:]
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
    private(set) var checkingAccounts = false
    /// Claude's plan limits from `/usage`, refreshed in the background.
    private(set) var planUsage: PlanUsage?
    private(set) var cursorUsage: CursorUsage?
    private(set) var cursorUsageProblem: String?
    private var usageTimer: Timer?
    private(set) var ledger = UsageLedger()
    /// The install / sign-in / update command shown in the setup terminal.
    var setupTask: SetupTask?
    /// Git identities + SSH keys the user switches between per project.
    private(set) var gitAccounts: [GitAccount] = []
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
    }

    // MARK: Lookup

    func sessions(of projectID: UUID) -> [ChatSession] {
        sessions.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func project(_ id: UUID?) -> Project? {
        projects.first { $0.id == id }
    }

    var selectedSession: ChatSession? {
        selectedSessionID.flatMap { sessions[$0] }
    }

    func isRunning(_ sessionID: UUID) -> Bool {
        running[sessionID] != nil
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
        sessions[sessionID]?.items.contains { $0.permissionState == .pending } ?? false
    }

    func models(for agent: AgentKind) -> [AgentModel] {
        switch agent {
        case .claude, .antigravity: agent.builtInModels
        case .cursor: cursorModels
        case .codex: agent.builtInModels + codexModels.map(\.model)
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
        }
    }

    /// Efforts the session's agent and model take: Claude's fixed list, the Codex model's
    /// own list; empty where effort isn't a separate choice (Cursor folds it into the model).
    func efforts(for session: ChatSession) -> [String] {
        switch session.agent {
        case .claude, .antigravity: Effort.levels
        case .codex:
            codexModels.first { $0.model.id == session.models[.codex] }?.efforts
                ?? codexModels.first?.efforts ?? ["low", "medium", "high", "xhigh"]
        case .cursor: []
        }
    }

    private var runner: AgentRunner {
        AgentRunner(locator: ExecutableLocator(overrides: AppSettings.executableOverrides))
    }

    // MARK: Projects

    private func load() {
        do {
            projects = try store.loadProjects()
        } catch {
            alert = "Could not read projects: \(error.localizedDescription)"
        }
        for project in projects {
            for var session in store.loadSessions(of: project.id) {
                // The agent that asked is gone after a restart.
                for index in session.items.indices where session.items[index].permissionState == .pending {
                    session.items[index].permissionState = .expired
                }
                sessions[session.id] = session
            }
        }
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
        for session in sessions(of: project.id) {
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
        for session in sessions(of: project.id) {
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
        sessions[sessionID] = nil
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
        case .claude, .codex, .antigravity:
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

    private func persist(_ sessionID: UUID) {
        guard let session = sessions[sessionID] else { return }
        do {
            try store.save(session)
        } catch {
            alert = "Could not save the session: \(error.localizedDescription)"
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
        guard let session = sessions[sessionID], running[sessionID] == nil,
              let project = project(session.projectID)
        else { return }
        let agent = session.agent
        let missed = session.unseenItems(for: agent)
        let prompt = PromptBuilder.prompt(text, attachments: attachments, missed: missed)

        let startBranch = branches.branch(of: project.path)
        update(sessionID) { session in
            if session.items.isEmpty { session.title = PromptBuilder.title(from: text) }
            if let startBranch { session.branch = startBranch }
            if !missed.isEmpty {
                session.items.append(ChatItem(kind: .notice, agent: agent, text: "\(agent.displayName) was given the turns it missed."))
            }
            var item = ChatItem(kind: .user, text: text, attachments: attachments)
            if !images.isEmpty { item.images = images.map(\.path) }
            session.items.append(item)
        }
        persist(sessionID)

        guard project.exists else {
            fail(sessionID, agent: agent, "The project folder \(project.path) no longer exists.")
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
            workingDirectory: project.url,
            additionalDirectories: project.additionalURLs.filter { !missing.contains($0.path) },
            loadsAdditionalRules: project.loadsAdditionalRules,
            model: session.models[agent],
            effort: [.claude, .codex, .antigravity].contains(agent) ? session.efforts[agent] : nil,
            access: accessOverride ?? session.access,
            resumeSessionID: session.agentSessionIDs[agent],
            sessionTitle: session.title
        )
        request.images = images
        let run: AgentRun
        do {
            run = try runner.start(request, with: AgentProviders.provider(for: agent))
        } catch {
            fail(sessionID, agent: agent, error.localizedDescription)
            onFinish?()
            return
        }
        running[sessionID] = run

        Task {
            var reducer = TranscriptReducer(agent: agent)
            for await event in run.events {
                switch event {
                case .failure(let message) where message.contains("No conversation found")
                    || (message.localizedCaseInsensitiveContains("session") && message.localizedCaseInsensitiveContains("not found")):
                    // The CLI no longer has this session; start fresh next time.
                    update(sessionID) { $0.agentSessionIDs[agent] = nil }
                case .rateLimit(let info):
                    setPlanUsage(planUsage?.updated(with: info) ?? PlanUsage.from(info))
                case .permissionRequest(let request):
                    pendingPermissions[request.id] = request
                    if !NSApp.isActive, let session = sessions[sessionID] {
                        Notifier.permissionNeeded(session: session, request: request)
                    }
                default:
                    break
                }
                update(sessionID) { reducer.apply(event, to: &$0) }
            }
            running[sessionID] = nil
            onFinish?()
            lastResults[sessionID] = reducer.lastResult
            if let result = reducer.lastResult {
                ledger.record(result, agent: agent)
                try? store.save(ledger, named: "usage")
            }
            if agent == .cursor { refreshCursorUsage() }
            // Agents may switch branches during a turn; remember where this session ended up.
            branches.refresh(project.path)
            let endBranch = branches.branch(of: project.path)
            update(sessionID) { session in
                session.seenCounts[agent] = session.items.count
                if let endBranch { session.branch = endBranch }
            }
            persist(sessionID)
            if NSApp.isActive == false, let session = sessions[sessionID] {
                Notifier.turnFinished(session: session, result: reducer.lastResult)
            }
        }
    }

    func stop(_ sessionID: UUID) {
        running[sessionID]?.cancel()
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
        let state: PermissionState = run.respond(reply, to: request)
            ? (reply == .deny ? .denied : reply == .allowAlways ? .alwaysAllowed : .allowed)
            : .expired
        setPermissionState(state, item: itemID, in: sessionID)
    }

    /// Lets a call Cursor refused through and asks it to try again. "Once" adds the rule to
    /// `.cursor/cli.json` only for the retry; without a known rule the retry runs with full access.
    func retryBlocked(item itemID: UUID, in sessionID: UUID, always: Bool) {
        guard let session = sessions[sessionID], running[sessionID] == nil,
              let project = project(session.projectID),
              let item = session.items.first(where: { $0.id == itemID }), item.permissionState == .blocked
        else { return }
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
        let probe = AccountProbe(runner: runner)
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
