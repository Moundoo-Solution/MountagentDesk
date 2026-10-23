import MountagentDeskKit
import SwiftUI

extension EnvironmentValues {
    /// The session's project, so rows can show paths relative to its folders.
    @Entry var project: Project?
    /// The session the rows belong to, for rows with actions.
    @Entry var sessionID: UUID?
}

struct ItemRow: View {
    let item: ChatItem
    let previous: ChatItem?
    var isStreaming = false

    /// The agent's name heads the first row of each reply, since a session can switch agents.
    private var showsAgentHeader: Bool {
        guard item.kind != .user, item.kind != .notice, item.agent != nil else { return false }
        return previous == nil || previous?.kind == .user || previous?.agent != item.agent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsAgentHeader, let agent = item.agent {
                AgentHeader(agent: agent)
            }
            switch item.kind {
            case .user: UserBubble(item: item)
            case .assistant: AssistantText(item: item)
            case .thinking: ThinkingRow(item: item, isStreaming: isStreaming)
            case .tool: ToolRow(item: item)
            case .permission: PermissionRow(item: item)
            case .notice: NoticeRow(item: item)
            }
        }
    }
}

private struct AgentHeader: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Image(symbol: agent.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(agent.tint)
                .frame(width: 14)
            Text(agent.displayName)
                .font(Theme.Font.uiMedium)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 6)
    }
}

// MARK: - Messages

private struct UserBubble: View {
    let item: ChatItem
    @Environment(\.project) private var project
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Spacer(minLength: 72)
            CopyButton(text: item.text)
                .opacity(hovering ? 1 : 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.text)
                    .font(Theme.Font.body)
                    .lineSpacing(Theme.Font.bodyLineSpacing)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.userFill, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous).strokeBorder(Theme.stroke))
                if let images = item.images, !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(images, id: \.self) { path in
                            ImageThumbnail(url: URL(fileURLWithPath: path), fitsWithin: CGSize(width: 240, height: 180))
                        }
                    }
                }
                if !item.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.attachments, id: \.self) { path in
                            Label(project?.displayPath(path) ?? path, systemImage: "doc.text")
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct AssistantText: View {
    let item: ChatItem

    var body: some View {
        MarkdownText(item.text)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Theme.success : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .hoverHighlight()
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

// MARK: - Turn actions

/// Under each finished reply: rate, copy, fork, and when it was written.
struct TurnActions: View {
    let turn: ArraySlice<ChatItem>
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.sessionID) private var sessionID

    /// Ratings and forks attach to the reply's last assistant message (or its last row).
    private var anchor: ChatItem? {
        turn.last { $0.kind == .assistant } ?? turn.last
    }

    private var text: String {
        turn.filter { $0.kind == .assistant }.map(\.text).joined(separator: "\n\n")
    }

    var body: some View {
        HStack(spacing: 2) {
            if let anchor, let sessionID {
                action(anchor.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup", help: "Good reply", active: anchor.rating == 1) {
                    model?.rate(1, item: anchor.id, in: sessionID)
                }
                action(anchor.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", help: "Bad reply", active: anchor.rating == -1) {
                    model?.rate(-1, item: anchor.id, in: sessionID)
                }
                CopyButton(text: text)
                    .disabled(text.isEmpty)
                action("arrow.triangle.branch", help: "Fork: new session from here") {
                    model?.fork(sessionID, through: anchor.id)
                }
                if model?.isRunning(sessionID) == false, model?.checkpoint(beforeTurnOf: anchor.id, in: sessionID) != nil {
                    action("arrow.uturn.backward", help: "Revert this turn: put the files back as they were before it") {
                        model?.revertTurn(of: anchor.id, in: sessionID)
                    }
                }
                Text(anchor.date.age)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 6)
                    .help(anchor.date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(.leading, 2)
    }

    private func action(_ symbol: String, help: String, active: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 22, height: 22)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .buttonStyle(.plain)
        .help(help)
    }

}

// MARK: - Thinking

private struct ThinkingRow: View {
    let item: ChatItem
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16)
                    if isStreaming {
                        // A timeline rather than a repeating animation, which would keep
                        // redrawing after the thought is done.
                        TimelineView(.animation(minimumInterval: Theme.animationInterval)) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                            Text("Thinking…").opacity(0.45 + 0.55 * abs(cos(phase * .pi)))
                        }
                    } else {
                        Text("Thought")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .font(Theme.Font.toolLabel)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .hoverHighlight()
            }
            .buttonStyle(.plain)

            if expanded {
                Text(item.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.hairline).frame(width: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 13)
            }
        }
    }
}

// MARK: - Tools

enum ToolStyle {
    static func symbol(for name: String?) -> String {
        switch name?.lowercased() ?? "" {
        case "read", "readfile": "doc.text"
        case "edit", "multiedit", "write", "writefile", "notebookedit", "applypatch": "pencil"
        case "bash", "shell", "terminal": "terminal"
        case "grep", "glob", "search", "semanticsearch", "ls", "toolsearch": "magnifyingglass"
        case "webfetch", "websearch", "fetch": "globe"
        case "mcp", "getmcptools": "puzzlepiece.extension"
        case "task", "agent": "person.2"
        case "todowrite", "todo", "updatetodos": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    static func tint(for name: String?) -> Color {
        switch name?.lowercased() ?? "" {
        case "edit", "multiedit", "write", "writefile", "notebookedit", "applypatch": Theme.Tool.edit
        case "bash", "shell", "terminal": Theme.Tool.shell
        case "grep", "glob", "search", "semanticsearch", "ls", "toolsearch": Theme.Tool.search
        case "webfetch", "websearch", "fetch": Theme.Tool.web
        case "task", "agent", "mcp", "getmcptools": Theme.Tool.agent
        default: Theme.textTertiary
        }
    }

    /// Verb shown before the target, e.g. "Ran", "Edited".
    static func verb(for name: String?) -> String {
        switch name?.lowercased() ?? "" {
        case "read", "readfile": "Read"
        case "edit", "multiedit", "applypatch": "Edited"
        case "write", "writefile": "Wrote"
        case "bash", "shell", "terminal": "Ran"
        case "grep", "search", "semanticsearch", "toolsearch": "Searched"
        case "glob", "ls": "Listed"
        case "webfetch", "fetch": "Fetched"
        case "websearch": "Searched web"
        case "mcp": "Called"
        case "getmcptools": "Looked up"
        case "todowrite", "updatetodos": "Updated todos"
        default: name ?? "Tool"
        }
    }
}

private struct ToolRow: View {
    let item: ChatItem
    @Environment(\.project) private var project
    @State private var expanded = false
    @State private var hovering = false

    private var target: String { project?.displayPath(item.text) ?? item.text }
    private var hasOutput: Bool { item.toolOutput?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard hasOutput else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    icon.frame(width: 16)
                    Text(ToolStyle.verb(for: item.toolName))
                        .font(Theme.Font.toolLabel)
                        .foregroundStyle(item.toolStatus == .failed ? Theme.danger : Theme.textSecondary)
                        .fixedSize()
                    Text(target)
                        .font(Theme.Font.toolTarget)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let summary {
                        Text(summary)
                            .font(Theme.Font.caption)
                            .foregroundStyle(item.toolStatus == .failed ? Theme.danger : Theme.textTertiary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hasOutput && (hovering || expanded) ? 1 : 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded, let output = item.toolOutput {
                ToolOutput(command: isShell ? item.text : nil, output: output)
                    .transition(.opacity)
            }
        }
    }

    private var isShell: Bool {
        ["bash", "shell"].contains(item.toolName?.lowercased() ?? "")
    }

    @ViewBuilder
    private var icon: some View {
        switch item.toolStatus {
        case .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: ToolStyle.symbol(for: item.toolName))
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
        default:
            Image(systemName: ToolStyle.symbol(for: item.toolName))
                .font(.system(size: 11))
                .foregroundStyle(ToolStyle.tint(for: item.toolName))
        }
    }

    /// Trailing hint: "84 lines", "failed".
    private var summary: String? {
        if item.toolStatus == .failed { return "failed" }
        guard let output = item.toolOutput, !output.isEmpty else { return nil }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
        return lines > 1 ? "\(lines) lines" : nil
    }
}

private struct ToolOutput: View {
    let command: String?
    let output: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let command {
                    Text("$ " + command)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(output)
                    .foregroundStyle(Theme.textPrimary)
            }
            .font(Theme.Font.code)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.codeBlock, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.codeBlock, style: .continuous).strokeBorder(Theme.hairline))
        .padding(.leading, 30)
    }
}

/// Three or more read-only lookups in a row, folded into one line.
struct ExploredGroup: View {
    let items: [ChatItem]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "binoculars")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Tool.search)
                        .frame(width: 16)
                    Text("Explored")
                        .font(Theme.Font.toolLabel)
                        .foregroundStyle(Theme.textSecondary)
                    Text(description)
                        .font(Theme.Font.toolLabel)
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .hoverHighlight()
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { ItemRow(item: $0, previous: $0) }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var description: String {
        let reads = items.filter { ["read", "readfile"].contains($0.toolName?.lowercased() ?? "") }.count
        let searches = items.count - reads
        return [reads > 0 ? "\(reads) file\(reads == 1 ? "" : "s")" : nil, searches > 0 ? "\(searches) search\(searches == 1 ? "" : "es")" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

// MARK: - Permissions

private struct PermissionRow: View {
    let item: ChatItem
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.sessionID) private var sessionID
    @Environment(\.project) private var project
    @State private var showsDetail = false

    private var agentName: String { item.agent?.shortName ?? "The agent" }
    private var summary: String { project?.displayPath(item.text) ?? item.text }
    private var isRunning: Bool { sessionID.map { model?.isRunning($0) ?? false } ?? false }

    var body: some View {
        switch item.permissionState {
        case .pending: request.transition(.opacity.combined(with: .move(edge: .bottom)))
        case .blocked: blocked
        default: resolved
        }
    }

    /// Claude is waiting: answer now.
    private var request: some View {
        card {
            header(icon: "exclamationmark.shield.fill", title: "\(agentName) wants to \(action)")
            command
            if showsDetail, let detail = item.toolOutput, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(Theme.Font.code)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack(spacing: 8) {
                Button(showsDetail ? "Hide details" : "Show details") {
                    withAnimation(.snappy(duration: 0.2)) { showsDetail.toggle() }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Deny") { answer(.deny) }
                    .keyboardShortcut(.escape, modifiers: [])
                if let rule = item.permissionRule {
                    Button("Always Allow") { answer(.allowAlways) }
                        .help("Saves \(rule) to .claude/settings.local.json")
                }
                Button("Allow") { answer(.allow) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    /// Cursor was refused without asking: allow it and retry the turn.
    private var blocked: some View {
        card {
            header(icon: "hand.raised.fill", title: "\(agentName) needs approval to \(action)")
            command
            HStack(spacing: 8) {
                Text(item.permissionRule ?? "Retrying runs it once with full access.")
                    .font(item.permissionRule == nil ? Theme.Font.caption : Theme.Font.toolTarget)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Dismiss") {
                    if let sessionID { model?.dismissBlocked(item: item.id, in: sessionID) }
                }
                if item.permissionRule != nil {
                    Button("Always Allow") { retry(always: true) }
                        .help("Saves the rule to .cursor/cli.json and retries")
                }
                Button("Allow & Retry") { retry(always: false) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .disabled(isRunning)
        }
    }

    private var resolved: some View {
        let (icon, color, verb): (String, Color, String) = switch item.permissionState {
        case .allowed: ("checkmark.shield", Theme.success, "Allowed")
        case .alwaysAllowed: ("checkmark.shield.fill", Theme.success, "Always allowed")
        case .denied: ("xmark.shield", Theme.danger, "Denied")
        case .retriedOnce: ("arrow.clockwise", Theme.success, "Allowed once")
        case .retriedAlways: ("arrow.clockwise", Theme.success, "Always allowed")
        case .dismissed: ("hand.raised.slash", Theme.textTertiary, "Blocked")
        default: ("clock", Theme.textTertiary, "Not answered")
        }
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(verb)
                .font(Theme.Font.toolLabel)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            Text(summary)
                .font(Theme.Font.toolTarget)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
    }

    private var action: String {
        switch item.toolName?.lowercased() ?? "" {
        case "bash", "shell": "run a command"
        case "mcp": "use an MCP tool"
        case "edit", "write", "multiedit": "edit a file"
        case "webfetch": "fetch a web page"
        default: "use \(item.toolName ?? "a tool")"
        }
    }

    private var command: some View {
        Text(summary)
            .font(Theme.Font.code)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.codeBlock, style: .continuous))
    }

    private func header(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Theme.warning)
            Text(title)
                .foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.warning.opacity(0.4)))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private func answer(_ reply: PermissionReply) {
        if let sessionID { withAnimation(.snappy(duration: 0.2)) { model?.answer(reply, item: item.id, in: sessionID) } }
    }

    private func retry(always: Bool) {
        if let sessionID { model?.retryBlocked(item: item.id, in: sessionID, always: always) }
    }
}

// MARK: - Notices

private struct NoticeRow: View {
    let item: ChatItem
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.sessionID) private var sessionID

    var body: some View {
        if item.isError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                Text(item.text)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .padding(10)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.codeBlock, style: .continuous))
        } else {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(item.text)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                if item.checkpoint != nil, let sessionID {
                    Button("Undo") { model?.undoRevert(item.id, in: sessionID) }
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(model?.isRunning(sessionID) != false)
                        .help("Bring back the files as they were before the revert")
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
        }
    }
}
