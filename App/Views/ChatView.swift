import MountagentDeskKit
import SwiftUI

extension EnvironmentValues {
    /// Whether this pane has focus: its composer takes the keyboard and its shortcuts.
    @Entry var isActivePane = true
    /// The pane a view sits in, so focusing its composer focuses the pane.
    @Entry var paneIndex = 0
    /// Composer chips show icons only, for narrow panes.
    @Entry var compactChips = false
}

/// The chat area: a top bar for the focused session, then one, two or four panes side by
/// side, each its own session, and the right-hand panel for the focused session's project.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    var sidebarVisible = true
    var toggleSidebar: () -> Void = {}
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @AppStorage(AppSettings.inspectorWidthKey) private var inspectorWidth = AppSettings.defaultInspectorWidth
    /// Git's History rows need room for the subject, author, date and reference chips.
    private static let inspectorRange: ClosedRange<Double> = 360...1000

    /// The conversations keep at least this much; the panel gives way when the window is
    /// narrow, rather than pushing the whole layout past the window's edges.
    private var minimumPanesWidth: Double {
        switch model.grid.layout {
        case .single, .rows: 540
        case .columns, .grid: 2 * 380
        }
    }

    private func inspectorRange(in width: Double) -> ClosedRange<Double> {
        let upper = min(Self.inspectorRange.upperBound, width - minimumPanesWidth)
        let lower = min(Self.inspectorRange.lowerBound, max(upper, 240))
        return lower...max(lower, upper)
    }

    var body: some View {
        let session = model.selectedSession
        let project = model.project(session?.projectID)
        VStack(spacing: 0) {
            topBar(session, project: project)
            GeometryReader { geometry in
                let range = inspectorRange(in: geometry.size.width)
                HStack(spacing: 0) {
                    PaneArea()
                    if inspectorVisible, let project, let session {
                        PaneResizeHandle(width: $inspectorWidth, edge: .trailing, range: range, defaultWidth: AppSettings.defaultInspectorWidth)
                        InspectorView(project: project, sessionID: session.id)
                            .frame(width: min(max(inspectorWidth, range.lowerBound), range.upperBound))
                            .transition(.move(edge: .trailing))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .animation(.snappy(duration: 0.2), value: inspectorVisible)
        .animation(.snappy(duration: 0.2), value: model.grid.layout)
        .background(Theme.background)
        .navigationTitle(session?.title ?? "Mountagent Desk")
        .background { paneShortcuts }
    }

    /// ⌃1…⌃4 focus a pane.
    private var paneShortcuts: some View {
        ForEach(0..<model.grid.layout.paneCount, id: \.self) { index in
            Button("Pane \(index + 1)") { model.focusPane(index) }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                .hidden()
        }
    }

    private func topBar(_ session: ChatSession?, project: Project?) -> some View {
        ChromeBar(leadingInset: sidebarVisible ? 0 : 66) {
            if !sidebarVisible {
                ChromeButton(symbol: "sidebar.left", help: "Show Sidebar (⌃⌘S)", action: toggleSidebar)
                    .padding(.trailing, 6)
            }
            if let session {
                Text(session.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let project {
                    Text(subtitle(for: project))
                        .font(Theme.Font.ui)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.leading, 6)
                    BranchChip(session: session, project: project)
                        .padding(.leading, 8)
                }
            }
            Spacer(minLength: 12)
            LayoutPicker()
                .padding(.trailing, 6)
            ChromeButton(symbol: "book.closed", help: "Rules & Skills (⇧⌘K)") {
                model.contextProject = project
            }
            .disabled(project == nil)
            ChromeButton(symbol: "sidebar.right", help: inspectorVisible ? "Hide the side panel (⌥⌘I)" : "Show Changes, Git, Browser, Terminal & Files (⌥⌘I)") {
                inspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            Menu {
                if let project {
                    Button("New Session", systemImage: "square.and.pencil") { model.newSession(in: project, agent: session?.agent) }
                    Button("Folders & Name…", systemImage: "folder") { model.foldersProject = project }
                    Button("Reveal in Finder", systemImage: "finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                }
                Divider()
                AppearanceMenu()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .chipMenu()
            .help("More")
        }
    }

    private func subtitle(for project: Project) -> String {
        let extra = project.additionalPaths.count
        return extra == 0 ? project.name : "\(project.name) · \(extra + 1) folders"
    }
}

// MARK: - Layout picker

/// One pane, two side by side, two stacked, or a 2×2 grid.
private struct LayoutPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 1) {
            ForEach(PaneGrid.Layout.allCases, id: \.self) { layout in
                let selected = model.grid.layout == layout
                Button {
                    model.setLayout(layout)
                } label: {
                    Image(systemName: layout.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 24, height: 22)
                        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(layout.help)
            }
        }
        .padding(2)
        .background(Theme.hover.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.chip + 2, style: .continuous))
    }
}

extension PaneGrid.Layout {
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .columns: "rectangle.split.2x1"
        case .rows: "rectangle.split.1x2"
        case .grid: "rectangle.split.2x2"
        }
    }

    var help: String {
        switch self {
        case .single: "One pane"
        case .columns: "Two panes side by side"
        case .rows: "Two panes, one above the other"
        case .grid: "Four panes"
        }
    }
}

// MARK: - Panes

/// Lays the panes out with draggable dividers between them.
private struct PaneArea: View {
    @Environment(AppModel.self) private var model
    @AppStorage("paneSplitX") private var splitX = 0.5
    @AppStorage("paneSplitY") private var splitY = 0.5
    @State private var clicks = PaneClickTracker()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let left = (width - 1) * splitX
            let top = (height - 1) * splitY
            Group {
                switch model.grid.layout {
                case .single:
                    pane(0)
                case .columns:
                    HStack(spacing: 0) {
                        pane(0).frame(width: left)
                        SplitDivider(axis: .vertical, ratio: $splitX, length: width)
                        pane(1)
                    }
                case .rows:
                    VStack(spacing: 0) {
                        pane(0).frame(height: top)
                        SplitDivider(axis: .horizontal, ratio: $splitY, length: height)
                        pane(1)
                    }
                case .grid:
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            pane(0).frame(width: left)
                            SplitDivider(axis: .vertical, ratio: $splitX, length: width)
                            pane(1)
                        }
                        .frame(height: top)
                        SplitDivider(axis: .horizontal, ratio: $splitY, length: height)
                        HStack(spacing: 0) {
                            pane(2).frame(width: left)
                            SplitDivider(axis: .vertical, ratio: $splitX, length: width)
                            pane(3)
                        }
                    }
                }
            }
            .frame(width: width, height: height)
        }
        .onAppear { clicks.install(model) }
        .onDisappear { clicks.uninstall() }
    }

    private func pane(_ index: Int) -> some View {
        SessionPane(index: index, sessionID: model.grid.visible[index], isActive: model.grid.focused == index, showsHeader: model.grid.layout != .single)
            .onHover { inside in
                if inside { clicks.hovered = index } else if clicks.hovered == index { clicks.hovered = nil }
            }
    }
}

/// A click anywhere in a pane (transcript text included, which SwiftUI gestures don't see)
/// focuses that pane.
@MainActor
private final class PaneClickTracker {
    var hovered: Int?
    private var monitor: Any?

    func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak model] event in
            if let index = self?.hovered, let model, model.grid.focused != index { model.focusPane(index) }
            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// A 1pt line between panes; drag to move it, double-click to split evenly.
private struct SplitDivider: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    @Binding var ratio: Double
    let length: CGFloat
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        let active = hovering || start != nil
        Rectangle()
            .fill(active ? Theme.accent : Theme.hairline)
            .frame(width: axis == .vertical ? (active ? 2 : 1) : nil, height: axis == .horizontal ? (active ? 2 : 1) : nil)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: axis == .vertical ? 10 : nil, height: axis == .horizontal ? 10 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        let cursor: NSCursor = axis == .vertical ? .resizeLeftRight : .resizeUpDown
                        if inside { cursor.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = start ?? ratio
                                if start == nil { start = ratio }
                                let delta = axis == .vertical ? value.translation.width : value.translation.height
                                ratio = min(0.8, max(0.2, base + delta / max(length, 1)))
                            }
                            .onEnded { _ in start = nil }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy(duration: 0.2)) { ratio = 0.5 }
                    }
            }
            .zIndex(1)
    }
}

/// One pane: its session's chat, or a picker when it is empty. Sessions dragged from the
/// sidebar can be dropped on it.
private struct SessionPane: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let sessionID: UUID?
    let isActive: Bool
    let showsHeader: Bool
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let sessionID, let session = model.sessions[sessionID] {
                SessionChat(session: session, index: index, isActive: isActive, showsHeader: showsHeader)
                    .id(sessionID)
            } else {
                EmptyPane(index: index, showsHeader: showsHeader)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.isActivePane, isActive)
        .environment(\.paneIndex, index)
        .overlay {
            let session = sessionID.flatMap { model.sessions[$0] }
            let running = session.map { model.isRunning($0.id) } ?? false
            ZStack {
                if running, let session {
                    WorkingGlow(tint: session.agent.tint)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.4), value: running)
        }
        .overlay {
            if dropTargeted {
                Rectangle().strokeBorder(Theme.accent, lineWidth: 2).background(Theme.accent.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.open(id, inPane: index)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// A light that circles a pane's edge in the agent's color while it works. With Reduce
/// Motion on, the light holds still.
private struct WorkingGlow: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let lap: Double = 2.4

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.lap) / Self.lap
            let light = AngularGradient(
                stops: [
                    .init(color: tint.opacity(0), location: 0),
                    .init(color: tint.opacity(0), location: 0.55),
                    .init(color: tint, location: 0.96),
                    .init(color: tint.opacity(0), location: 1),
                ],
                center: .center,
                angle: .degrees(phase * 360)
            )
            ZStack {
                Rectangle().strokeBorder(tint.opacity(0.25), lineWidth: 1)
                Rectangle().strokeBorder(light, lineWidth: 6).blur(radius: 6).opacity(0.7)
                Rectangle().strokeBorder(light, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A session's transcript and composer, under a small header when the area is split.
private struct SessionChat: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    let index: Int
    let isActive: Bool
    let showsHeader: Bool
    @State private var draft = ""

    var body: some View {
        let project = model.project(session.projectID)
        VStack(spacing: 0) {
            if showsHeader {
                PaneHeader(session: session, project: project, index: index, isActive: isActive)
            }
            TranscriptView(session: session, isRunning: model.isRunning(session.id), draft: $draft)
                .environment(\.project, project)
                .environment(\.sessionID, session.id)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ComposerView(session: session, text: $draft)
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: .insertIntoComposer)) { note in
            guard isActive, let text = note.userInfo?["text"] as? String else { return }
            draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + text + " "
        }
    }
}

/// Agent, title, project and branch of a pane's session; the focused one is marked in the
/// agent's color.
private struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    let project: Project?
    let index: Int
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("\(index + 1)")
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(isActive ? Theme.background : Theme.textTertiary)
                .frame(width: 15, height: 15)
                .background(isActive ? session.agent.tint : Theme.selected, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .help("⌃\(index + 1)")
            Image(systemName: session.agent.symbolName)
                .font(.system(size: 10.5))
                .foregroundStyle(session.agent.tint)
            Text(session.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if let project {
                Text(project.name)
                    .font(Theme.Font.caption)
                    .foregroundStyle(project.tint)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 6)
            if model.hasPendingPermission(session.id) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
            } else if model.isRunning(session.id) {
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            }
            Button { model.clearPane(index) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .buttonStyle(.plain)
            .help("Close this pane's session (it stays in the sidebar)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(isActive ? session.agent.tint.opacity(0.08) : Theme.sidebar.opacity(0.5))
        .overlay(alignment: .bottom) {
            Rectangle().fill(isActive ? session.agent.tint.opacity(0.7) : Theme.hairline).frame(height: isActive ? 1.5 : 1)
        }
    }
}

/// An empty pane: recent sessions to open here, or a new one.
private struct EmptyPane: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let showsHeader: Bool

    private var recent: [ChatSession] {
        model.sessions.values
            .filter { model.grid.pane(showing: $0.id) == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(systemName: showsHeader ? PaneGrid.Layout.grid.symbol : "bubble.left.and.bubble.right")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textTertiary)
                Text(showsHeader ? "Pane \(index + 1)" : "No session selected")
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("Open a session here, drag one in from the sidebar, or start a new one.")
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if !recent.isEmpty {
                VStack(spacing: 1) {
                    ForEach(recent) { session in
                        Button {
                            model.open(session.id, inPane: index)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: session.agent.symbolName)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(session.agent.tint)
                                    .frame(width: 14)
                                Text(session.title)
                                    .font(Theme.Font.ui)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let project = model.project(session.projectID) {
                                    Text(project.name).font(Theme.Font.caption).foregroundStyle(project.tint).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .hoverHighlight()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .frame(maxWidth: 360)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.stroke))
            }
            if let project = model.project(model.selectedSession?.projectID) ?? model.projects.first {
                Button {
                    model.focusPane(index)
                    model.newSession(in: project)
                } label: {
                    Label("New Session in \(project.name)", systemImage: "square.and.pencil")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// "⎇ AB-005-U1-login-form" plus the git account's avatar. Turns orange when the repo
/// has moved to another branch since this session last ran.
struct BranchChip: View {
    @Environment(AppModel.self) private var model
    let session: ChatSession
    let project: Project

    var body: some View {
        let current = model.branch(of: project)
        let moved = session.branch != nil && current != nil && session.branch != current
        if current != nil || session.branch != nil {
            HStack(spacing: 5) {
                Image(systemName: moved ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(current ?? session.branch ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let account = model.gitAccount(project.gitAccountID) {
                    GitAccountAvatar(account: account, size: 14)
                }
            }
            .foregroundStyle(moved ? Theme.warning : project.tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background((moved ? Theme.warning : project.tint).opacity(0.13), in: Capsule())
            .help(tooltip(current: current, moved: moved))
        }
    }

    private func tooltip(current: String?, moved: Bool) -> String {
        var lines: [String] = []
        if moved, let last = session.branch, let current {
            lines.append("This session last worked on \(last); the repository is now on \(current).")
        }
        for path in project.allPaths {
            if let branch = model.branches.branch(of: path) {
                lines.append("\((path as NSString).lastPathComponent): \(branch)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct AppearanceMenu: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
        Picker(selection: $appearance) {
            ForEach(Appearance.allCases) { option in
                Label(option.title, systemImage: option.symbolName).tag(option)
            }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
        }
        .onChange(of: appearance) { appearance.apply() }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let session: ChatSession
    let isRunning: Bool
    @Binding var draft: String

    var body: some View {
        if session.items.isEmpty {
            EmptySession(agent: session.agent, draft: $draft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    TranscriptRows(items: session.items, isRunning: isRunning)
                    // Scrolling to this keeps the last line clear of the composer's fade.
                    Color.clear.frame(height: 32).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: Theme.columnWidth + 48)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .modifier(SoftTopEdge())
            .onChange(of: session.items.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .task {
                // Lazy rows settle their heights after the first layout pass.
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

/// The transcript's rows with their spacing, for whichever stack hosts them. Each finished
/// reply ends with its action bar.
struct TranscriptRows: View {
    let items: [ChatItem]
    let isRunning: Bool

    var body: some View {
        let rows = TranscriptRow.build(from: items)
        let positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            VStack(alignment: .leading, spacing: 8) {
                switch row {
                case .item(let item, let previous):
                    ItemRow(item: item, previous: previous, isStreaming: isRunning && index == rows.count - 1)
                case .explored(let items):
                    ExploredGroup(items: items)
                }
                if endsTurn(rows, at: index), let end = positions[row.lastItem.id] {
                    TurnActions(turn: turn(endingAt: end))
                }
            }
            .padding(.top, index == 0 ? 0 : row.topSpacing(after: rows[index - 1]))
        }
    }

    /// The last reply row before the next user message; notices in between don't count.
    private func endsTurn(_ rows: [TranscriptRow], at index: Int) -> Bool {
        let last = rows[index].lastItem
        guard ![.user, .notice].contains(last.kind), last.agent != nil else { return false }
        guard let next = rows[(index + 1)...].first(where: { $0.firstItem.kind != .notice }) else { return !isRunning }
        return next.firstItem.kind == .user
    }

    /// The items of the reply ending at `end`, back to the user message before it.
    private func turn(endingAt end: Int) -> ArraySlice<ChatItem> {
        var start = end
        while start > 0, items[start - 1].kind != .user { start -= 1 }
        return items[start...end]
    }
}

/// What the transcript lays out: single items, or runs of read-only lookups folded into
/// one "Explored" row so a long turn stays scannable.
enum TranscriptRow: Identifiable {
    case item(ChatItem, previous: ChatItem?)
    case explored([ChatItem])

    var id: UUID {
        switch self {
        case .item(let item, _): item.id
        case .explored(let items): items[0].id
        }
    }

    var firstItem: ChatItem {
        switch self {
        case .item(let item, _): item
        case .explored(let items): items[0]
        }
    }

    var lastItem: ChatItem {
        switch self {
        case .item(let item, _): item
        case .explored(let items): items[items.count - 1]
        }
    }

    /// Compact one-line rows, stacked tightly.
    private var isToolLike: Bool {
        if case .explored = self { return true }
        switch firstItem.kind {
        case .tool, .thinking: return true
        case .permission: return ![.pending, .blocked].contains(firstItem.permissionState)
        default: return false
        }
    }

    func topSpacing(after previous: TranscriptRow) -> CGFloat {
        if firstItem.kind == .user { return Theme.turnSpacing }
        // The agent header opens a reply and the first tool row follows it closely.
        if isToolLike && previous.isToolLike { return 2 }
        return Theme.itemSpacing
    }

    static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "LS", "Ls", "ReadFile", "Search", "GetMcpTools", "ToolSearch", "SemanticSearch"]

    static func build(from items: [ChatItem]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [ChatItem] = []
        var previous: ChatItem?

        func flush() {
            if run.count >= 3 {
                rows.append(.explored(run))
            } else {
                for item in run {
                    rows.append(.item(item, previous: previous))
                    previous = item
                }
            }
            if let last = run.last { previous = last }
            run = []
        }

        for item in items {
            if item.kind == .tool, item.toolStatus == .succeeded, readOnlyTools.contains(item.toolName ?? "") {
                run.append(item)
                continue
            }
            flush()
            rows.append(.item(item, previous: previous))
            previous = item
        }
        flush()
        return rows
    }
}

private struct SoftTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct EmptySession: View {
    @Environment(\.project) private var project
    let agent: AgentKind
    @Binding var draft: String

    private let starters: [(String, String)] = [
        ("text.magnifyingglass", "Explain how this codebase is organised"),
        ("ladybug", "Find and fix a bug in "),
        ("checklist", "Review my uncommitted changes"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(agent.tint)
                .frame(width: 36, height: 36)
                .background(Theme.userFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
            VStack(spacing: 4) {
                Text("New session in \(project?.name ?? "this project")")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let project {
                    Text((project.path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Font.ui)
                        .foregroundStyle(Theme.textSecondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .frame(maxWidth: 460)
                }
            }
            VStack(spacing: 2) {
                ForEach(starters, id: \.1) { symbol, text in
                    Button {
                        draft = text
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol)
                                .frame(width: 18)
                                .foregroundStyle(Theme.textTertiary)
                            Text(text.trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .font(Theme.Font.ui)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 360)
            .padding(.top, 10)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 40)
    }
}
