import MountagentDeskKit
import SwiftUI

/// Cursor-style sidebar: a flat, darker column with action rows at the top, one collapsible
/// group per project and 12pt session cells (padding 6/8/6/5, radius 6, hover 6% ink,
/// selection 8% ink).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    let toggleSidebar: () -> Void
    @State private var renaming: ChatSession?
    @State private var newTitle = ""
    @AppStorage("collapsedProjects") private var collapsedStore = ""

    private var collapsed: Set<String> {
        Set(collapsedStore.split(separator: ",").map(String.init))
    }

    var body: some View {
        VStack(spacing: 0) {
            ChromeBar(leadingInset: 66) {
                Spacer()
                ChromeButton(symbol: "sidebar.left", help: "Hide Sidebar (⌃⌘S)", action: toggleSidebar)
            }

            VStack(spacing: 1) {
                ActionCell(symbol: "square.and.pencil", title: "New Session", shortcut: "⌘N") {
                    if let project = model.project(model.selectedSession?.projectID) ?? model.projects.first {
                        model.newSession(in: project)
                    } else {
                        model.chooseProjectFolder()
                    }
                }
                ActionCell(symbol: "folder.badge.plus", title: "Add Project", shortcut: "⌘O") {
                    model.chooseProjectFolder()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.projects) { project in
                        projectGroup(project)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            AccountUsageSection()
            SidebarFooter()
        }
        .background(Theme.sidebar)
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let session = renaming { model.rename(session.id, to: newTitle) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func projectGroup(_ project: Project) -> some View {
        let key = project.id.uuidString
        let isExpanded = !collapsed.contains(key)
        let sessions = model.sessions(of: project.id)
        return VStack(alignment: .leading, spacing: 1) {
            GroupTitle(project: project, isExpanded: isExpanded) {
                var set = collapsed
                if isExpanded { set.insert(key) } else { set.remove(key) }
                collapsedStore = set.sorted().joined(separator: ",")
            }
            if isExpanded {
                ForEach(sessions) { session in
                    SessionCell(
                        session: session,
                        tint: project.tint,
                        currentBranch: model.branch(of: project),
                        isSelected: model.selectedSessionID == session.id,
                        pane: model.grid.layout == .single ? nil : model.grid.pane(showing: session.id),
                        isRunning: model.isRunning(session.id),
                        needsApproval: model.hasPendingPermission(session.id),
                        select: { model.selectedSessionID = session.id },
                        rename: {
                            newTitle = session.title
                            renaming = session
                        },
                        delete: { model.confirmDelete(session.id) }
                    )
                }
                let archived = model.archivedSessions(of: project.id)
                if !archived.isEmpty {
                    ArchivedSessions(sessions: archived)
                }
                if sessions.isEmpty {
                    Text("No sessions")
                        .font(Theme.Font.ui)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                }
            }
        }
    }
}

/// "New Session ⌘N" style rows under the chrome bar.
private struct ActionCell: View {
    let symbol: String
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(shortcut)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 8))
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct GroupTitle: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(project.tint)
                        .padding(.trailing, 2)
                    Text(project.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(Theme.textPrimary)
                    if !project.additionalPaths.isEmpty {
                        Text("+\(project.additionalPaths.count)")
                    }
                    if !project.missingPaths.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .help("Missing: \(project.missingPaths.joined(separator: ", "))")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(hovering ? 1 : 0)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Group {
                Menu {
                    Button("New Session in Own Worktree") { model.newSessionInWorktree(in: project) }
                        .help("A new branch and working copy next to the repository, so this session's agent doesn't edit the files other sessions work on")
                    Divider()
                    Button("Folders & Name…") { model.foldersProject = project }
                    Button("Rules & Skills…") { model.contextProject = project }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                    if CursorApp.isInstalled {
                        Button("Open in Cursor") { CursorApp.open([project.url]) }
                    }
                    Divider()
                    Section("Last 30 days") {
                        Text(model.usageSummary(of: project) ?? "No turns yet")
                        Button("Export Usage as CSV…") { model.exportUsageCSV() }
                    }
                    Divider()
                    Button("Remove Project…", role: .destructive) { model.confirmRemove(project) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                        .hoverHighlight(cornerRadius: Theme.Radius.chip)
                }
                .chipMenu()

                Menu {
                    ForEach(model.agentChoices) { agent in
                        Button {
                            model.newSession(in: project, agent: agent)
                        } label: {
                            Label { Text("New \(agent.displayName) Session") } icon: { Image(symbol: agent.symbolName) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                        .hoverHighlight(cornerRadius: Theme.Radius.chip)
                } primaryAction: {
                    model.newSession(in: project)
                }
                .chipMenu()
                .help("New session (hold to choose the agent)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(project.allPaths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
    }
}

private struct SessionCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: ChatSession
    /// The project's color: the selected cell is washed with it and carries a bar.
    let tint: Color
    let currentBranch: String?
    let isSelected: Bool
    /// The pane showing this session when the chat area is split.
    let pane: Int?
    let isRunning: Bool
    let needsApproval: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            status
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(Theme.Font.ui)
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundStyle(isSelected || isActive ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .mask(fadeMask)
                if let branch = session.branch {
                    let moved = session.worktree == nil && currentBranch != nil && currentBranch != branch
                    HStack(spacing: 3) {
                        Image(systemName: moved ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                            .font(.system(size: 8, weight: .semibold))
                        Text(branch)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(moved ? Theme.warning : Theme.textTertiary)
                    .help(moved ? "Last worked on \(branch); the repository is now on \(currentBranch ?? "")." : "Branch this session last worked on")
                }
            }
            Spacer(minLength: 0)
            if let pane {
                Text("\(pane + 1)")
                    .font(.system(size: 9.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.background : Theme.textSecondary)
                    .frame(width: 15, height: 15)
                    .background(isSelected ? session.agent.tint : Theme.selected, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .help("Open in pane \(pane + 1)")
            }
            ZStack(alignment: .trailing) {
                trailingStatus
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: 2) {
                    cellAction("pencil", help: "Rename", action: rename)
                    cellAction("trash", help: "Delete", action: delete)
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 5, bottom: 6, trailing: 8))
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay(alignment: .leading) {
            if isSelected || isActive {
                Capsule().fill(activeTint ?? tint).frame(width: 3, height: 16).offset(x: -1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .draggable(session.id.uuidString) {
            // Drop it on a pane to open it there.
            Label { Text(session.title) } icon: { Image(symbol: session.agent.symbolName) }
                .font(Theme.Font.ui)
                .padding(6)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…", action: rename)
            Button("Export as Markdown…") { model.exportMarkdown(session.id) }
            Button("Archive") { model.setArchived(true, for: session.id) }
                .disabled(isRunning)
            if let worktree = session.worktree {
                Divider()
                Button("Open Worktree in Git Window") { openWindow(id: "git", value: worktree) }
                Button("Reveal Worktree in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree)]) }
                Button("Remove Worktree…") { model.removeWorktree(of: session.id) }
                    .disabled(isRunning)
            }
            Divider()
            Button("Delete Session", role: .destructive, action: delete)
        }
    }

    /// Working or waiting on you: the row stands out even when it isn't selected.
    private var isActive: Bool { isRunning || needsApproval }

    /// Amber while it waits for an answer, the agent's color while it works.
    private var activeTint: Color? {
        needsApproval ? Theme.warning : isRunning ? session.agent.tint : nil
    }

    private var background: Color {
        if let activeTint { return activeTint.opacity(isSelected ? 0.20 : 0.12) }
        return isSelected ? tint.opacity(0.14) : hovering ? Theme.hover : .clear
    }

    /// "Needs you" or a pulsing "Working" in place of the age while the agent is busy.
    @ViewBuilder
    private var trailingStatus: some View {
        if needsApproval {
            Text("Needs you")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.warning)
        } else if isRunning {
            TimelineView(.animation(minimumInterval: Theme.animationInterval)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Text("Working")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(session.agent.tint)
                    .opacity(0.55 + 0.45 * abs(cos(phase * .pi)))
            }
        } else {
            Text(session.updatedAt.shortAge)
                .font(Theme.Font.caption)
                .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textTertiary)
                .monospacedDigit()
        }
    }

    /// Long titles fade out at the trailing edge instead of ending in an ellipsis.
    private var fadeMask: some View {
        LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
    }

    private func cellAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var status: some View {
        if needsApproval {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warning)
                .help("Waiting for your approval")
        } else if isRunning {
            WorkingSpinner(tint: session.agent.tint)
                .help("\(session.agent.displayName) is working")
        } else {
            Image(symbol: session.agent.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? session.agent.tint : session.agent.tint.opacity(0.75))
                .help(session.agent.displayName)
        }
    }

}

/// A ring turning in the agent's color, with the agent's mark inside: easier to spot than
/// the system's small grey spinner.
private struct WorkingSpinner: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: Theme.animationInterval)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(tint.opacity(0.2), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
                Circle().fill(tint).frame(width: 4, height: 4)
            }
            .frame(width: 13, height: 13)
        }
    }
}

/// Each enabled agent's account and plan usage at a glance, as in Claude Code's own panel.
/// Collapsible; "View details" opens Settings → Agents.
private struct AccountUsageSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage("accountUsageExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("ACCOUNT & USAGE")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("View details") {
                    SettingsPane.show(.agents)
                    openSettings()
                }
                    .buttonStyle(.plain)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .underline()
            }

            if expanded {
                ForEach(Array(model.agentChoices.enumerated()), id: \.element) { index, kind in
                    agentHeader(kind)
                        .padding(.top, index == 0 ? 0 : 8)
                    usage(for: kind)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    @ViewBuilder
    private func usage(for kind: AgentKind) -> some View {
        if model.needsSetup(kind) {
            Button("Set up \(kind.displayName)…") { model.setUp(kind) }
                .buttonStyle(.link)
                .font(Theme.Font.ui)
        } else {
            switch kind {
            case .claude:
                if let usage = model.planUsage {
                    ForEach(usage.limits.prefix(3), id: \.name) { limit in
                        UsageMeter(limit: limit)
                    }
                } else {
                    Text("Reading usage…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            case .cursor:
                CursorUsageMeters()
            case .codex where model.codexUsage != nil:
                if let usage = model.codexUsage {
                    ForEach(usage.limits, id: \.name) { UsageMeter(limit: $0) }
                    Text("As of the last Codex turn, \(usage.fetchedAt.formatted(.relative(presentation: .named)))")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            case .copilot where model.copilotUsage != nil:
                if let usage = model.copilotUsage?.usage {
                    ForEach(usage.limits, id: \.name) { UsageMeter(limit: $0) }
                    ForEach(usage.notes, id: \.self) { note in
                        Text(note).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            case .codex, .antigravity, .copilot:
                // Their CLIs don't report plan limits; show what went through Mountagent Desk today.
                let today = model.ledger.total(for: kind, lastDays: 1)
                // Copilot reports premium requests, not tokens.
                let tokens = today.totalTokens == 0 ? "" : " · \(today.totalTokens.formatted(.number.notation(.compactName))) tokens"
                Text(today.turns == 0 ? "No turns today" : "Today: \(today.turns) turn\(today.turns == 1 ? "" : "s")" + tokens)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// "Claude · you@… · Team"
    private func agentHeader(_ kind: AgentKind) -> some View {
        let account = model.account(kind)
        return HStack(spacing: 6) {
            Image(symbol: kind.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 14)
            Text(kind.shortName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 6)
            Text([account?.email, kind == .copilot ? model.copilotUsage?.plan ?? account?.plan : account?.plan].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    /// An agent to install or sign in to: the gear carries a dot and opens on Agents.
    private var needsSetup: Bool { model.anyAgentNeedsSetup }

    var body: some View {
        HStack(spacing: 2) {
            Button {
                if needsSetup { SettingsPane.show(.agents) }
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if needsSetup {
                            Circle().fill(Theme.warning).frame(width: 6, height: 6).offset(x: -3, y: 4)
                        }
                    }
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .buttonStyle(.plain)
            .help(needsSetup ? "Settings (⌘,): an agent needs setting up" : "Settings (⌘,)")

            Spacer()

            Menu {
                AppearanceMenu().pickerStyle(.inline)
            } label: {
                Image(systemName: appearance.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .chipMenu()
            .help("Appearance")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }
}

/// A project's archived sessions, folded under its list: open one to bring it back.
private struct ArchivedSessions: View {
    @Environment(AppModel.self) private var model
    let sessions: [ChatSession]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Archived (\(sessions.count))")
                    Spacer()
                }
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(sessions) { session in
                    HStack(spacing: 6) {
                        Image(symbol: session.agent.symbolName)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                        Text(session.title)
                            .font(Theme.Font.ui)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.setArchived(false, for: session.id)
                        model.selectedSessionID = session.id
                    }
                    .help("Unarchive and open")
                    .contextMenu {
                        Button("Unarchive") { model.setArchived(false, for: session.id) }
                        Button("Export as Markdown…") { model.exportMarkdown(session.id) }
                        Divider()
                        Button("Delete Session", role: .destructive) { model.confirmDelete(session.id) }
                    }
                }
            }
        }
    }
}
