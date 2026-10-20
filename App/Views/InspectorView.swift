import MountagentDeskKit
import SwiftUI
import WebKit

/// The right-hand panel, as in Cursor's Agents window: "On <branch>" with Changes, Git,
/// Browser, Terminal and Files. Picking one opens it in the panel; the back button returns.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let project: Project
    let sessionID: UUID
    @AppStorage("inspectorTool") private var toolStore = ""
    @State private var changes = ChangesState()

    enum Tool: String, CaseIterable {
        case changes, git, browser, terminal, files

        var title: String {
            switch self {
            case .changes: "Changes"
            case .git: "Git"
            case .browser: "Browser"
            case .terminal: "Terminal"
            case .files: "Files"
            }
        }

        var symbol: String {
            switch self {
            case .changes: "plusminus"
            case .git: "arrow.triangle.branch"
            case .browser: "globe"
            case .terminal: "apple.terminal"
            case .files: "doc"
            }
        }
    }

    private var tool: Tool? { Tool(rawValue: toolStore) }

    var body: some View {
        VStack(spacing: 0) {
            if let tool {
                header(tool)
                Group {
                    switch tool {
                    case .changes: ChangesPanel(project: project, state: changes)
                    case .git: GitPanel(project: project)
                    case .browser: BrowserPanel(project: project)
                    case .terminal: TerminalPanel(project: project)
                    case .files: FilesPanel(project: project)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                home
            }
        }
        .background(Theme.sidebar)
        .task(id: project.id) { await changes.refresh(project) }
        .onChange(of: model.isRunning(sessionID)) { _, running in
            // Agents change files; refresh when a turn ends.
            if !running { Task { await changes.refresh(project) } }
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
                    HStack(spacing: 8) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 16)
                        Text(tool.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textPrimary)
                        if tool == .changes, changes.additions + changes.deletions > 0 {
                            DiffStat(additions: changes.additions, deletions: changes.deletions)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
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
            Image(systemName: tool.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
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
    let project: Project
    let state: ChangesState
    @State private var selected: (folder: String, change: GitInspector.FileChange)?
    @State private var diff = ""

    var body: some View {
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
                DiffView(diff: diff)
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

/// A unified diff with added and removed lines tinted.
struct DiffView: View {
    let diff: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(Theme.Font.code)
                        .foregroundStyle(foreground(line))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                        .background(background(line))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
        .background(Theme.codeBackground)
    }

    /// Hunks only; git's file headers repeat what the panel header shows.
    private var lines: [String] {
        diff.components(separatedBy: "\n").drop { !$0.hasPrefix("@@") }.map { $0 }
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

// MARK: - Browser

/// Web views live per project so pages survive switching panels and sessions.
@MainActor
final class BrowserStore {
    static let shared = BrowserStore()
    private var views: [UUID: WKWebView] = [:]

    func view(for project: Project) -> WKWebView {
        if let view = views[project.id] { return view }
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = true
        views[project.id] = view
        return view
    }
}

private struct BrowserPanel: View {
    let project: Project
    @State private var address = ""
    @AppStorage("browserLastURL") private var lastURL = "http://localhost:8069"

    var body: some View {
        let webView = BrowserStore.shared.view(for: project)
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ChromeButton(symbol: "chevron.left", help: "Back") { webView.goBack() }
                ChromeButton(symbol: "chevron.right", help: "Forward") { webView.goForward() }
                ChromeButton(symbol: "arrow.clockwise", help: "Reload") { webView.reload() }
                TextField("Address", text: $address)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Theme.userFill, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairline))
                    .onSubmit { load(address, in: webView) }
                ChromeButton(symbol: "safari", help: "Open in default browser") {
                    if let url = webView.url { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            WebView(view: webView)
        }
        .onAppear {
            address = webView.url?.absoluteString ?? lastURL
            if webView.url == nil { load(address, in: webView) }
        }
    }

    private func load(_ text: String, in webView: WKWebView) {
        var string = text.trimmingCharacters(in: .whitespaces)
        guard !string.isEmpty else { return }
        if !string.contains("://") { string = (string.hasPrefix("localhost") || string.first?.isNumber == true ? "http://" : "https://") + string }
        guard let url = URL(string: string) else { return }
        address = string
        lastURL = string
        webView.load(URLRequest(url: url))
    }
}

private struct WebView: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Terminal

private struct TerminalPanel: View {
    let project: Project
    @Environment(\.colorScheme) private var colorScheme
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
            TerminalHost(project: project, dark: colorScheme == .dark)
                .id(generation)
                .padding(.leading, 8)
                .padding(.vertical, 4)
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
