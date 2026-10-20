import MountagentDeskKit
import SwiftUI

/// The window: a flat sidebar and the conversation, each with its own 40pt chrome bar,
/// drawn edge to edge under a hidden title bar, as in Cursor's Agents window.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.sidebarWidthKey) private var sidebarWidth = AppSettings.defaultSidebarWidth
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(toggleSidebar: toggleSidebar)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                PaneResizeHandle(width: $sidebarWidth, range: 200...520, defaultWidth: AppSettings.defaultSidebarWidth)
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.snappy(duration: 0.2), value: sidebarVisible)
        .sheet(item: $model.contextProject) { project in
            ContextView(project: project)
        }
        .sheet(item: $model.foldersProject) { project in
            FoldersView(project: project)
        }
        .sheet(item: model.setupBinding(for: .main)) { SetupSheet(task: $0) }
        .alert("Mountagent Desk", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in toggleSidebar() }
    }

    @ViewBuilder
    private var detail: some View {
        if !model.projects.isEmpty {
            ChatView(sidebarVisible: sidebarVisible, toggleSidebar: toggleSidebar)
        } else {
            VStack(spacing: 0) {
                ChromeBar(leadingInset: sidebarVisible ? 0 : 78) {
                    if !sidebarVisible {
                        ChromeButton(symbol: "sidebar.left", help: "Show Sidebar (⌃⌘S)", action: toggleSidebar)
                    }
                    Spacer()
                }
                WelcomeView()
            }
        }
    }

    private func toggleSidebar() {
        sidebarVisible.toggle()
    }
}

extension Notification.Name {
    static let toggleSidebar = Notification.Name("MountagentDesk.toggleSidebar")
}

/// A 40pt bar across the top of a pane; empty parts drag the window.
struct ChromeBar<Content: View>: View {
    var leadingInset: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(.leading, 12 + leadingInset)
        .padding(.trailing, 10)
        .frame(height: Theme.chromeHeight)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
    }
}

/// A 1pt pane divider that resizes the pane on its `edge` side when dragged. The grab
/// area is 10pt wide and drawn above both neighbours so it is easy to hit; it lights up on
/// hover, and a double-click restores `defaultWidth`.
struct PaneResizeHandle: View {
    enum Edge { case leading, trailing }

    @Binding var width: Double
    var edge: Edge = .leading
    var range: ClosedRange<Double> = 200...640
    var defaultWidth: Double?
    @State private var start: Double?
    @State private var hovering = false

    private var active: Bool { hovering || start != nil }

    var body: some View {
        Rectangle()
            .fill(active ? Theme.accent : Theme.hairline)
            .frame(width: active ? 2 : 1)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // The stored width may be more than fits now; drag from what is shown.
                                let base = start ?? min(range.upperBound, max(range.lowerBound, width))
                                if start == nil { start = base }
                                let delta = edge == .leading ? value.translation.width : -value.translation.width
                                width = min(range.upperBound, max(range.lowerBound, base + delta))
                            }
                            .onEnded { _ in start = nil }
                    )
                    .onTapGesture(count: 2) {
                        if let defaultWidth {
                            withAnimation(.snappy(duration: 0.2)) { width = defaultWidth }
                        }
                    }
            }
            .animation(.easeOut(duration: 0.12), value: active)
            .zIndex(1)
            .ignoresSafeArea()
            .help("Drag to resize · double-click to reset")
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(model.agentChoices) { agent in
                    Image(systemName: agent.symbolName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(agent.tint)
                        .frame(width: 36, height: 36)
                        .background(Theme.userFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
                }
            }
            VStack(spacing: 6) {
                Text("Mountagent Desk")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Claude Code, Cursor, Codex and Antigravity in one place. Add a project with one folder or several; rules and skills stay in the project, so every agent shares them.")
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button {
                model.chooseProjectFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Add Project")
                    Text("⌘O").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.Font.uiMedium)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Theme.selected, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.hairline))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}
