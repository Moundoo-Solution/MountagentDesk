import MountagentDeskKit
import SwiftUI

/// The right-hand panel, as in Cursor's Agents window: "On <branch>" with Changes, Git,
/// Terminal, Servers and Files. Picking one opens it in the panel; the back button returns.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project
    let sessionID: UUID
    @AppStorage("inspectorTool") private var toolStore = ""
    @AppStorage("accountUsageExpanded") private var usageExpanded = true
    @AppStorage("accountUsageHeight") private var usageHeight = 320.0
    @State private var changes = ChangesState()

    enum Tool: String, CaseIterable {
        case changes, git, terminal, servers, files

        var title: String {
            switch self {
            case .changes: "Changes"
            case .git: "Git"
            case .terminal: "Terminal"
            case .servers: "Servers"
            case .files: "Files"
            }
        }

        var symbol: String {
            switch self {
            case .changes: "plusminus"
            case .git: "arrow.triangle.branch"
            case .terminal: "apple.terminal"
            case .servers: "server.rack"
            case .files: "doc"
            }
        }

        /// The same hues as the matching Settings panes.
        var tint: Color {
            switch self {
            case .changes: Color(light: 0x0F8A5F, dark: 0x2EA772)
            case .git: Color(light: 0x1F6FEB, dark: 0x2F81F7)
            case .terminal: Color(light: 0x4B5563, dark: 0x6B7280)
            case .servers: Color(light: 0xB25E09, dark: 0xE08A2E)
            case .files: Color(light: 0x8B3FD9, dark: 0x9F67F0)
            }
        }
    }

    private var tool: Tool? { Tool(rawValue: toolStore) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let tool {
                    header(tool)
                    Group {
                        switch tool {
                        case .changes: ChangesPanel(project: project, state: changes, sessionID: sessionID)
                        case .git: GitPanel(project: project)
                        case .terminal: TerminalPanel(project: project)
                        case .servers: ServersPanel(project: project)
                        case .files: FilesPanel(project: project)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    home
                }
                usage(in: geometry.size.height)
            }
        }
        .background(Theme.sidebar)
        .task(id: project.id) { await changes.refresh(project) }
        .onChange(of: model.isRunning(sessionID)) { _, running in
            // Agents change files; refresh when a turn ends.
            if !running { Task { await changes.refresh(project) } }
        }
    }

    /// Account & Usage at the foot, as tall as the user dragged it (leaving the panel above
    /// some room); folded, just its title row.
    @ViewBuilder
    private func usage(in height: Double) -> some View {
        if usageExpanded {
            let range = 120...max(120, height - 160)
            HeightResizeHandle(height: $usageHeight, range: range, defaultHeight: 320)
            ScrollView {
                AccountUsageSection()
            }
            .scrollIndicators(.automatic)
            .frame(height: min(max(usageHeight, range.lowerBound), range.upperBound))
        } else {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            AccountUsageSection()
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("On \(model.branch(of: project) ?? changes.branch ?? project.name)")
                    .lineLimit(1)
                if let account = model.gitAccount(project.gitAccountID) {
                    Spacer(minLength: 4)
                    GitAccountAvatar(account: account, size: 16)
                    Text(account.githubLogin ?? account.label)
                        .lineLimit(1)
                }
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            ForEach(Tool.allCases, id: \.self) { tool in
                Button {
                    toolStore = tool.rawValue
                } label: {
                    HStack(spacing: 9) {
                        TintedIcon(symbol: tool.symbol, tint: tool.tint, size: 20)
                        Text(tool.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        if tool == .changes, changes.additions + changes.deletions > 0 {
                            DiffStat(additions: changes.additions, deletions: changes.deletions)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 32)
                    .hoverHighlight()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
    }

    private func header(_ tool: Tool) -> some View {
        HStack(spacing: 4) {
            ChromeButton(symbol: "chevron.left", help: "Back") { toolStore = "" }
            TintedIcon(symbol: tool.symbol, tint: tool.tint, size: 16)
                .padding(.trailing, 2)
            Text(tool.title)
                .font(Theme.Font.uiMedium)
                .foregroundStyle(Theme.textPrimary)
            if tool == .changes, changes.additions + changes.deletions > 0 {
                DiffStat(additions: changes.additions, deletions: changes.deletions)
                    .font(Theme.Font.caption)
            }
            Spacer()
            if tool == .changes {
                ChromeButton(symbol: "arrow.clockwise", help: "Refresh") {
                    Task { await changes.refresh(project) }
                }
            }
            if tool == .changes || tool == .git {
                ChromeButton(symbol: "macwindow", help: "Open Git in its own window (⇧⌘G)") {
                    openWindow(id: "git", value: project.path)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Theme.success)
            Text("-\(deletions)").foregroundStyle(Theme.danger)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }
}

// MARK: - Changes

/// Git state for every repository among the project's folders.
@MainActor
@Observable
final class ChangesState {
    struct Repo: Identifiable {
        var folder: String
        var summary: GitInspector.Summary
        var id: String { folder }
    }

    private(set) var repos: [Repo] = []
    private(set) var loading = false

    var branch: String? { repos.first?.summary.branch }
    var additions: Int { repos.reduce(0) { $0 + $1.summary.additions } }
    var deletions: Int { repos.reduce(0) { $0 + $1.summary.deletions } }

    func refresh(_ project: Project) async {
        loading = true
        let folders = project.allPaths
        let found = await Task.detached(priority: .userInitiated) {
            folders.compactMap { folder in
                GitInspector(root: URL(fileURLWithPath: folder)).summary().map { Repo(folder: folder, summary: $0) }
            }
        }.value
        repos = found
        loading = false
    }
}

private struct ChangesPanel: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let state: ChangesState
    let sessionID: UUID
    @State private var selected: (folder: String, change: GitInspector.FileChange)?
    @State private var diff = ""

    var body: some View {
        VStack(spacing: 0) {
            content
            if let comments = model.reviewComments[sessionID], !comments.isEmpty {
                reviewBar(comments)
            }
        }
        #if DEBUG
        // `MOUNTAGENT_OPEN_CHANGE=<path>` opens that file's diff, for snapshots, with
        // `MOUNTAGENT_REVIEW_NOTE` as a comment on its line 2.
        .onChange(of: state.repos.count) { _, _ in
            guard selected == nil, let path = ProcessInfo.processInfo.environment["MOUNTAGENT_OPEN_CHANGE"] else { return }
            for repo in state.repos {
                if let change = repo.summary.changes.first(where: { $0.path == path }) {
                    selected = (repo.folder, change)
                    if let note = ProcessInfo.processInfo.environment["MOUNTAGENT_REVIEW_NOTE"] {
                        model.addReviewComment(.init(path: change.path, line: 2, removed: false, code: "", text: note), in: sessionID)
                    }
                }
            }
        }
        #endif
    }

    /// The path the agent knows a file by: as in its repository, under the folder's name
    /// for repositories other than the main folder.
    private func agentPath(_ change: GitInspector.FileChange, in folder: String) -> String {
        folder == project.path ? change.path : (folder as NSString).lastPathComponent + "/" + change.path
    }

    private func reviewBar(_ comments: [DiffReview.Comment]) -> some View {
        let agent = model.sessions[sessionID]?.agent
        return HStack(spacing: 8) {
            Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
            Text("\(comments.count) comment\(comments.count == 1 ? "" : "s")")
                .font(Theme.Font.uiMedium)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Clear") { model.clearReview(in: sessionID) }
                .buttonStyle(.borderless)
                .controlSize(.small)
            Button("Send to \(agent?.shortName ?? "Agent")") { model.sendReview(in: sessionID) }
                .controlSize(.small)
                .help("One message with every comment, file by file")
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private var content: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        self.selected = nil
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    Text(selected.change.path)
                        .font(Theme.Font.toolTarget)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    DiffStat(additions: selected.change.additions, deletions: selected.change.deletions)
                        .font(Theme.Font.caption)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                DiffView(
                    diff: diff,
                    comments: (model.reviewComments[sessionID] ?? []).filter { $0.path == agentPath(selected.change, in: selected.folder) },
                    comment: { line, text in
                        guard let number = line.newNumber ?? line.oldNumber else { return }
                        model.addReviewComment(.init(path: agentPath(selected.change, in: selected.folder), line: number,
                                                     removed: line.kind == .removed, code: line.text, text: text), in: sessionID)
                    },
                    remove: { model.removeReviewComment($0, in: sessionID) }
                )
            }
            .task(id: selected.change.path) {
                let root = URL(fileURLWithPath: selected.folder)
                let change = selected.change
                diff = await Task.detached { GitInspector(root: root).diff(for: change) }.value
            }
        } else if state.repos.isEmpty {
            PanelPlaceholder(symbol: "plusminus", text: state.loading ? "Reading changes…" : "No git repository in this project.")
        } else if state.repos.allSatisfy({ $0.summary.changes.isEmpty }) {
            PanelPlaceholder(symbol: "checkmark.circle", text: "No uncommitted changes.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(state.repos) { repo in
                        if state.repos.count > 1 {
                            Text("\((repo.folder as NSString).lastPathComponent) · \(repo.summary.branch ?? "")")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                        }
                        ForEach(repo.summary.changes) { change in
                            ChangeRow(change: change) { selected = (repo.folder, change) }
                        }
                    }
                }
                .padding(6)
            }
        }
    }
}

struct ChangeRow: View {
    let change: GitInspector.FileChange
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ViewThatFits(in: .horizontal) {
                content(fullPath: true)
                content(fullPath: false)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(change.path)
    }

    /// The whole path when it fits; otherwise the name with its folder after it.
    private func content(fullPath: Bool) -> some View {
            HStack(spacing: 6) {
                Text(letter)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 12)
                Text(fullPath ? change.path : (change.path as NSString).lastPathComponent)
                    .font(Theme.Font.ui)
                    .foregroundStyle(change.status == .deleted ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(change.status == .deleted)
                    .lineLimit(1)
                    .fixedSize(horizontal: fullPath, vertical: false)
                if !fullPath {
                    Text((change.path as NSString).deletingLastPathComponent)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                if change.isBinary {
                    Text("binary").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    DiffStat(additions: change.additions, deletions: change.deletions)
                        .font(Theme.Font.caption)
                        .fixedSize()
                }
            }
    }

    private var letter: String {
        switch change.status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .untracked: "U"
        }
    }

    private var color: Color {
        switch change.status {
        case .added, .untracked: Theme.success
        case .deleted: Theme.danger
        default: Theme.warning
        }
    }
}

/// A unified diff with added and removed lines tinted. With `comment`, hovering a line
/// offers a comment on it; the comments left so far show under their lines.
struct DiffView: View {
    let diff: String
    var comments: [DiffReview.Comment] = []
    var comment: ((DiffReview.Line, String) -> Void)?
    var remove: (UUID) -> Void = { _ in }
    @State private var hovered: Int?
    @State private var editing: Int?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let lines = DiffReview.lines(of: diff)
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        row(line, index: index)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                            .background(background(line.text))
                        ForEach(comments.filter { matches($0, line) }) { note in
                            noteRow(note)
                                .frame(width: max(200, min(520, geometry.size.width - 40)))
                        }
                        if editing == index {
                            editor(for: line)
                                .frame(width: max(200, min(520, geometry.size.width - 40)))
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .background(Theme.codeBackground)
    }

    private func row(_ line: DiffReview.Line, index: Int) -> some View {
        HStack(spacing: 0) {
            if comment != nil {
                ZStack {
                    if hovered == index, line.kind != .hunk {
                        Button {
                            draft = ""
                            editing = index
                            focused = true
                        } label: {
                            Image(systemName: "plus.bubble.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Comment on this line")
                    }
                }
                .frame(width: 18)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.Font.code)
                .foregroundStyle(foreground(line.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, comment == nil ? 10 : 2)
        }
        .frame(minHeight: 17, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
    }

    private func matches(_ note: DiffReview.Comment, _ line: DiffReview.Line) -> Bool {
        note.removed ? (line.kind == .removed && line.oldNumber == note.line) : (line.kind != .removed && line.newNumber == note.line)
    }

    private func noteRow(_ note: DiffReview.Comment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "text.bubble").foregroundStyle(Theme.accent)
            Text(note.text)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { remove(note.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this comment")
        }
        .font(Theme.Font.ui)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.stroke))
        .padding(.leading, 20)
        .padding(.vertical, 3)
    }

    private func editor(for line: DiffReview.Line) -> some View {
        HStack(spacing: 6) {
            TextField("Comment for the agent", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { add(line) }
                .onExitCommand { editing = nil }
            Button("Add") { add(line) }
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { editing = nil }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.leading, 20)
        .padding(.vertical, 4)
    }

    private func add(_ line: DiffReview.Line) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        comment?(line, text)
        editing = nil
        draft = ""
    }

    private func foreground(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Theme.textTertiary }
        if line.hasPrefix("+") { return Theme.success }
        if line.hasPrefix("-") { return Theme.danger }
        return Theme.textPrimary
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("+") { return Theme.success.opacity(0.10) }
        if line.hasPrefix("-") { return Theme.danger.opacity(0.10) }
        return .clear
    }
}

private struct PanelPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Terminal

private struct TerminalPanel: View {
    let project: Project
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TerminalTheme.key) private var theme = TerminalTheme.app
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text((project.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
                ChromeButton(symbol: "arrow.counterclockwise", help: "Restart shell") {
                    TerminalStore.shared.restart(project)
                    generation += 1
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)
            TerminalHost(project: project, dark: colorScheme == .dark, theme: theme)
                .id(generation)
                .padding(.leading, 8)
                .padding(.vertical, 4)
                .background(theme.background(dark: colorScheme == .dark))
        }
        .background(Theme.codeBackground)
    }
}

// MARK: - Files

private struct FilesPanel: View {
    let project: Project
    @State private var preview: URL? = Self.initialPreview

    #if DEBUG
    /// `MOUNTAGENT_OPEN_FILE` opens that file, for snapshots of the viewer.
    private static let initialPreview = ProcessInfo.processInfo.environment["MOUNTAGENT_OPEN_FILE"].map(URL.init(fileURLWithPath:))
    #else
    private static let initialPreview: URL? = nil
    #endif

    var body: some View {
        if let preview {
            FilePreview(url: preview, project: project) { self.preview = nil }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(project.allPaths, id: \.self) { folder in
                        FileNodeRow(node: FileTree.Node(url: URL(fileURLWithPath: folder), isDirectory: true), depth: 0, startExpanded: folder == project.path) { preview = $0 }
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct FileNodeRow: View {
    let node: FileTree.Node
    let depth: Int
    var startExpanded = false
    let open: (URL) -> Void
    @State private var expanded: Bool?
    @State private var children: [FileTree.Node] = []

    private var isExpanded: Bool { expanded ?? startExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if node.isDirectory {
                    expanded = !isExpanded
                } else {
                    open(node.url)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(node.isDirectory ? 1 : 0)
                        .frame(width: 10)
                    let icon = FileIcon.symbol(for: node.name, isDirectory: node.isDirectory)
                    Image(systemName: icon.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(icon.color)
                        .frame(width: 14)
                    Text(node.name)
                        .font(Theme.Font.ui)
                        .foregroundStyle(depth == 0 ? Theme.textPrimary : Theme.textSecondary)
                        .fontWeight(depth == 0 ? .medium : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14 + 4)
                .frame(height: 24)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            }

            if node.isDirectory, isExpanded {
                ForEach(children) { child in
                    FileNodeRow(node: child, depth: depth + 1, open: open)
                }
            }
        }
        .task(id: isExpanded) {
            guard node.isDirectory, isExpanded, children.isEmpty else { return }
            let url = node.url
            children = await Task.detached { FileTree.children(of: url) }.value
        }
    }
}

private struct FilePreview: View {
    let url: URL
    let project: Project
    let close: () -> Void
    @State private var text: String?
    @State private var loaded = false
    @State private var position = CodePosition()
    @AppStorage("codeWraps") private var wraps = false

    private var language: CodeLanguage { CodeLanguage(fileName: url.lastPathComponent) }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let text {
                CodeView(text: text, language: language, wraps: wraps, position: $position)
                statusBar(text)
            } else if loaded {
                PanelPlaceholder(symbol: "doc", text: "No preview for this file.")
            } else {
                Spacer()
            }
        }
        .task(id: url) {
            let url = url
            loaded = false
            text = await Task.detached { FileTree.preview(url) }.value
            loaded = true
            position = CodePosition()
        }
    }

    /// Back, then the file as an editor tab (icon, name, folder), then actions.
    private var tabBar: some View {
        let icon = FileIcon.symbol(for: url.lastPathComponent, isDirectory: false)
        let folder = (project.displayPath(url.path) as NSString).deletingLastPathComponent
        return HStack(spacing: 6) {
            ChromeButton(symbol: "chevron.left", help: "Back to files", action: close)
            HStack(spacing: 6) {
                Image(systemName: icon.name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(icon.color)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                if !folder.isEmpty {
                    Text(folder)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .help(project.displayPath(url.path))
            Spacer(minLength: 4)
            ChromeButton(symbol: wraps ? "text.alignleft" : "arrow.right.to.line", help: wraps ? "Don't Wrap Lines" : "Wrap Lines") { wraps.toggle() }
            ChromeButton(symbol: "at", help: "Mention in message") {
                let path = project.agentPath(for: url)
                // Into the focused pane's composer.
                NotificationCenter.default.post(name: .insertIntoComposer, object: nil, userInfo: ["text": "`\(path)`"])
            }
            if CursorApp.isInstalled {
                ChromeButton(symbol: "arrow.up.forward.app", help: "Open in Cursor") { CursorApp.open([url]) }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func statusBar(_ text: String) -> some View {
        let lines = text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        return HStack(spacing: 14) {
            Text("Ln \(position.line), Col \(position.column)" + (position.selected > 0 ? " (\(position.selected) selected)" : ""))
            Spacer()
            Text("\(lines) lines")
            Text(language.title)
            Text("UTF-8")
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
