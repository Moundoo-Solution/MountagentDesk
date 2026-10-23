import MountagentDeskKit
import SwiftUI

/// The Settings window, laid out like Cursor's: a searchable list of panes on the left and
/// the chosen pane's grouped cards on the right, in the app's own colors.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsPane.key) private var pane = SettingsPane.general
    @State private var search = ""

    private var panes: [SettingsPane] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? SettingsPane.allCases : SettingsPane.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 216)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PaneHeader(pane: pane)
                    content
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
        }
        .frame(width: 900, height: 640)
        .background(Theme.sidebar)
        .sheet(item: model.setupBinding(for: .settings)) { SetupSheet(task: $0) }
        .onChange(of: search) {
            if let first = panes.first, !panes.contains(pane) { pane = first }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search settings", text: $search)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.ui)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .padding(.bottom, 10)

            ForEach(panes) { item in
                PaneRow(pane: item, selected: item == pane, badge: item == .agents && model.anyAgentNeedsSetup) {
                    pane = item
                }
            }
            if panes.isEmpty {
                Text("No settings match.")
                    .font(Theme.Font.ui)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(8)
            }
            Spacer()
            Text("Mountagent Desk \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 8)
        }
        .padding(12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .agents: AgentsPane()
        case .voice: VoicePane()
        case .git: GitPane()
        case .servers: ServersSettingsPane()
        case .paths: PathsPane()
        }
    }
}

// MARK: - Panes list

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, agents, voice, git, servers, paths

    static let key = "settingsPane"
    var id: String { rawValue }

    /// Opens Settings on this pane next time (the window reads it on appear).
    static func show(_ pane: SettingsPane) {
        UserDefaults.standard.set(pane.rawValue, forKey: key)
    }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .agents: "Agents"
        case .voice: "Voice"
        case .git: "Git Accounts"
        case .servers: "Servers"
        case .paths: "CLI Paths"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Defaults for new projects and sessions, and notifications."
        case .appearance: "How Mountagent Desk looks."
        case .agents: "Switch coding agents on or off, and see their accounts, plans and usage."
        case .voice: "Dictate messages instead of typing them."
        case .git: "The identities projects commit and push as. Pick one per project in Folders & Name; it goes into each repository's .git/config, so agents, terminals and other Git apps use it too."
        case .servers: "Live, UAT and test machines you reach over SSH. Link them to projects in Folders & Name, open terminals from the right panel's Servers, and decide per server whether agents may read it."
        case .paths: "Where Mountagent Desk finds each agent's command-line tool (claude, cursor-agent, codex, agy)."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintpalette.fill"
        case .agents: "person.2.fill"
        case .voice: "mic.fill"
        case .git: "arrow.triangle.branch"
        case .servers: "server.rack"
        case .paths: "terminal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(light: 0x6B7280, dark: 0x8B93A1)
        case .appearance: Color(light: 0x8B3FD9, dark: 0x9F67F0)
        case .agents: Color(light: 0xC15F3C, dark: 0xD97757)
        case .voice: Color(light: 0xD9304F, dark: 0xE5486A)
        case .git: Color(light: 0x1F6FEB, dark: 0x2F81F7)
        case .servers: Color(light: 0xB25E09, dark: 0xF0A04B)
        case .paths: Color(light: 0x0F8A5F, dark: 0x2EA772)
        }
    }

    private var keywords: String {
        switch self {
        case .general: "default agent access permission notification notify plan read only full"
        case .appearance: "theme dark light mode color sidebar width"
        case .agents: "claude cursor codex antigravity gemini opencode copilot kiro amp kimi grok mistral vibe droid terminal openai google enable disable on off account usage plan sign in login install update limit cost"
        case .voice: "microphone mic dictation speech language vietnamese english send"
        case .git: "github ssh key email name commit push identity avatar"
        case .servers: "server ssh live uat test production terminal log psql termius agent read only"
        case .paths: "cli path executable version claude cursor-agent terminal"
        }
    }

    func matches(_ query: String) -> Bool {
        query.lowercased().split(separator: " ").allSatisfy { word in
            title.lowercased().contains(word) || keywords.contains(word)
        }
    }
}

private struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        TintedIcon(symbol: pane.symbol, tint: pane.tint, size: size)
    }
}

private struct PaneRow: View {
    let pane: SettingsPane
    let selected: Bool
    let badge: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                PaneIcon(pane: pane)
                Text(pane.title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if badge {
                    Circle().fill(Theme.warning).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PaneIcon(pane: pane, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(pane.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows on one card.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
            if let footer {
                Text(footer)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Title and explanation on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.defaultAgentKey) private var defaultAgent = AgentKind.claude
    @AppStorage(AppSettings.defaultAccessKey) private var defaultAccess = AccessLevel.editFiles
    @AppStorage(AppSettings.notifyKey) private var notify = true
    @AppStorage(AppSettings.chimeKey) private var chime = true
    @AppStorage(AppSettings.badgeUnreadKey) private var badgeUnread = true

    var body: some View {
        SettingsSection(title: "New work") {
            SettingsRow(title: "Default agent", detail: "Used for new projects and new sessions. You can switch agents inside any chat.", divider: false) {
                Picker("Default agent", selection: Binding(get: { model.isEnabled(defaultAgent) ? defaultAgent : AppSettings.defaultAgent }, set: { defaultAgent = $0 })) {
                    ForEach(model.agentChoices) { agent in
                        Label { Text(agent.shortName) } icon: { Image(symbol: agent.symbolName) }.tag(agent)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRow(title: "Default access", detail: "What agents may do in a new session without asking.") {
                Picker("Default access", selection: $defaultAccess) {
                    ForEach(AccessLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }

        SettingsSection(title: "Notifications") {
            SettingsRow(title: "Agent finished", detail: "Notify when an agent finishes while Mountagent Desk is in the background.", divider: false) {
                Toggle("Agent finished", isOn: $notify).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Chime", detail: "A short sound when an agent finishes (or fails) while you're in the app.") {
                Toggle("Chime", isOn: $chime).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "Dock badge counts unread sessions", detail: "Besides questions waiting for you, count sessions that finished while you were elsewhere; they also get a dot in the sidebar.") {
                Toggle("Dock badge counts unread sessions", isOn: $badgeUnread).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsSection(title: "Access levels") {
            AccessExplanation(symbol: "eye", tint: Theme.Tool.web, title: AccessLevel.readOnly.displayName,
                              text: "Plan mode: the agents read and suggest, nothing is changed.", divider: false)
            AccessExplanation(symbol: "pencil", tint: Theme.Tool.edit, title: AccessLevel.editFiles.displayName,
                              text: "Agents edit files freely. Before commands and MCP tools, Claude asks in the chat; Cursor's blocked calls can be allowed and retried (rules go to .cursor/cli.json); Codex runs commands in its workspace sandbox; Antigravity refuses them.")
            AccessExplanation(symbol: "bolt.fill", tint: Theme.warning, title: AccessLevel.fullAccess.displayName,
                              text: "No checks: Claude skips permission prompts, Cursor runs with --force, Codex runs without its sandbox, Antigravity approves every tool.")
        }
    }
}

private struct AccessExplanation: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String
    var divider = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if divider { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 52) }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(AppSettings.sidebarWidthKey) private var sidebarWidth = AppSettings.defaultSidebarWidth
    @AppStorage(AppSettings.inspectorWidthKey) private var inspectorWidth = AppSettings.defaultInspectorWidth
    @AppStorage(TerminalTheme.key) private var terminalTheme = TerminalTheme.app

    var body: some View {
        SettingsSection(title: "Theme") {
            HStack(spacing: 14) {
                ForEach(Appearance.allCases) { option in
                    ThemeTile(option: option, selected: appearance == option) {
                        appearance = option
                        option.apply()
                    }
                }
            }
            .padding(16)
        }

        SettingsSection(title: "Terminal Colors", footer: "For the Terminal panel and server tabs. Programs choose which colors they use; ls, git and most prompts show them.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                ForEach(TerminalTheme.allCases) { option in
                    TerminalThemeTile(theme: option, selected: terminalTheme == option) {
                        terminalTheme = option
                    }
                }
            }
            .padding(16)
        }

        SettingsSection(title: "Layout") {
            SettingsRow(title: "Panel widths", detail: "Put the sidebar and the right panel back to their default widths.", divider: false) {
                Button("Reset") {
                    sidebarWidth = AppSettings.defaultSidebarWidth
                    inspectorWidth = AppSettings.defaultInspectorWidth
                }
            }
        }
    }
}

/// A few lines of a shell session in the scheme's colors.
private struct TerminalThemeTile: View {
    let theme: TerminalTheme
    let selected: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scheme = theme.scheme(dark: colorScheme == .dark)
        Button(action: select) {
            VStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    line([("deploy@uat", scheme.ansi[2]), (":", scheme.foreground), ("~", scheme.ansi[4]), ("$ ls", scheme.foreground)])
                    line([("app ", scheme.ansi[12]), ("config.yml ", scheme.foreground), ("run.sh", scheme.ansi[10])])
                    line([("ERROR ", scheme.ansi[9]), ("WARNING ", scheme.ansi[11]), ("INFO", scheme.ansi[14])])
                    line([("● ", scheme.ansi[13]), ("active (running)", scheme.ansi[2])])
                }
                .font(.system(size: 9, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .background(Color(nsColor: NSColor(hex: scheme.background)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Theme.action : Theme.stroke, lineWidth: selected ? 2 : 1)
                )
                Text(theme.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func line(_ parts: [(String, UInt32)]) -> some View {
        parts.reduce(Text("")) { text, part in
            text + Text(part.0).foregroundColor(Color(nsColor: NSColor(hex: part.1)))
        }
        .lineLimit(1)
    }
}

/// A miniature window in that appearance; System shows both halves.
private struct ThemeTile: View {
    let option: Appearance
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 8) {
                ZStack {
                    switch option {
                    case .light: preview(dark: false)
                    case .dark: preview(dark: true)
                    case .dim: preview(dark: true, dim: true)
                    case .system:
                        preview(dark: false)
                            .overlay { preview(dark: true).mask(DiagonalHalf()) }
                    }
                }
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Theme.action : Theme.stroke, lineWidth: selected ? 2 : 1)
                )
                HStack(spacing: 5) {
                    Image(systemName: option.symbolName).font(.system(size: 11))
                    Text(option.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                }
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func preview(dark: Bool, dim: Bool = false) -> some View {
        let background = Color(nsColor: NSColor(hex: !dark ? Theme.Hex.backgroundLight : dim ? Theme.Hex.backgroundDim : Theme.Hex.backgroundBlack))
        let sidebar = Color(nsColor: NSColor(hex: !dark ? Theme.Hex.sidebarLight : dim ? Theme.Hex.sidebarDim : Theme.Hex.sidebarBlack))
        let ink = Color(nsColor: NSColor(hex: dark ? Theme.Hex.inkDark : Theme.Hex.inkLight))
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { color in
                        Circle().fill(Color(nsColor: NSColor(hex: UInt32(color)))).frame(width: 5, height: 5)
                    }
                }
                .padding(.bottom, 4)
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2).fill(ink.opacity(index == 1 ? 0.25 : 0.12)).frame(width: index == 1 ? 34 : 28, height: 5)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 52)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.5)).frame(width: 50, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.15)).frame(height: 5)
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.15)).frame(width: 60, height: 5)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(ink.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.claude.opacity(0.8), lineWidth: 1))
                    .frame(height: 18)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(background)
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX * 0.62, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX * 0.38, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if model.checkingAccounts {
                ProgressView().controlSize(.small)
                Text("Checking…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button {
                model.refreshAccounts()
                model.refreshPlanUsage()
                model.refreshCursorUsage(userInitiated: true)
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
                    .font(Theme.Font.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, -14)
        ForEach(AgentKind.allCases) { kind in
            AgentCard(kind: kind)
        }
        .onAppear { model.refreshPlanUsage() }
        TerminalAgentsSection()
    }
}

/// Agents that run in their own terminal interface, as in SpaceVibe Deck: started from a
/// project's + menu or Quick Launch, installed here with the vendor's own command.
private struct TerminalAgentsSection: View {
    @Environment(AppModel.self) private var model
    @State private var installed: Set<String> = []

    var body: some View {
        SettingsSection(title: "Terminal agents", footer: "These run in their own interface in a terminal session, so the app shows their screen rather than a transcript: no approvals, usage or cost here. Later runs pick up the folder's last conversation where the CLI can (Kiro, Droid).") {
            ForEach(Array(TerminalCommands.agents.enumerated()), id: \.element.id) { index, agent in
                SettingsRow(title: "\(agent.name) · \(agent.vendor)", detail: installed.contains(agent.name) ? agent.command : "Not installed · \(agent.install)", divider: index > 0) {
                    HStack(spacing: 8) {
                        Image(systemName: agent.symbolName).foregroundStyle(agent.tint)
                        Link("Website", destination: agent.website)
                            .font(Theme.Font.caption)
                        if installed.contains(agent.name) {
                            Text("Installed").font(Theme.Font.caption).foregroundStyle(Theme.success)
                        } else {
                            Button("Install…") { model.install(agent, from: .settings) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        // Looked for again after an install sheet closes.
        .task(id: model.setupTask == nil) {
            installed = await Task.detached { Set(TerminalCommands.agents.filter(\.isInstalled).map(\.name)) }.value
        }
    }
}

// MARK: - Voice

private struct VoicePane: View {
    @AppStorage(AppSettings.dictationMicrophoneKey) private var microphone = ""
    @AppStorage(AppSettings.dictationLanguageKey) private var language = AppSettings.defaultDictationLanguage
    @AppStorage(AppSettings.dictationSendsKey) private var sends = false
    @State private var inputs: [AudioInput] = []
    @State private var systemDefault: AudioInput?
    @State private var test = SpeechDictation()

    var body: some View {
        SettingsSection(title: "Input", footer: "Click the mic in the chat box, or press ⇧⌘D, to dictate. With the lid closed the MacBook's own microphone hears nothing: pick the one you speak into.") {
            SettingsRow(title: "Microphone", detail: microphoneDetail, divider: false) {
                HStack(spacing: 6) {
                    Picker("Microphone", selection: $microphone) {
                        Text("System Default").tag("")
                        Divider()
                        ForEach(inputs) { input in
                            Text(input.name).tag(input.uid)
                        }
                        if !microphone.isEmpty, !inputs.contains(where: { $0.uid == microphone }) {
                            Text("Unplugged microphone").tag(microphone)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(action: reload) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Look for microphones again")
                }
            }
            SettingsRow(title: "Language", detail: "Words like sync, commit and staging are recognised in both.") {
                Picker("Language", selection: $language) {
                    ForEach(SpeechDictation.languages, id: \.id) { language in
                        Text(language.title).tag(language.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            SettingsRow(title: "Send when I stop talking", detail: "After a short pause, the message is sent without pressing Return.") {
                Toggle("Send when I stop talking", isOn: $sends).labelsHidden().toggleStyle(.switch)
            }
        }

        SettingsSection(title: "Test") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Button {
                        if test.isListening {
                            test.stop()
                        } else {
                            Task { await test.start(language: language, microphone: microphone) }
                        }
                    } label: {
                        Image(systemName: test.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background((test.isListening ? Theme.danger : SettingsPane.voice.tint).gradient, in: Circle())
                            .shadow(color: Theme.danger.opacity(test.isListening ? 0.25 + 0.4 * test.level : 0), radius: 4 + 10 * test.level)
                    }
                    .buttonStyle(.plain)
                    .help(test.isListening ? "Stop" : "Start test")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(test.isListening ? "Listening on \(test.microphone ?? "the microphone")…" : "Press the mic and say a sentence.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                        LevelBars(level: test.isListening ? test.level : 0)
                    }
                }
                Text(test.transcript.isEmpty ? "What you say appears here." : test.transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(test.transcript.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if test.hearsNothing {
                    Label("No sound from \(test.microphone ?? "this microphone"). Pick another one above.", systemImage: "mic.badge.xmark")
                        .font(Theme.Font.ui)
                        .foregroundStyle(Theme.warning)
                }
                switch test.status {
                case .denied(let message), .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.ui)
                        .foregroundStyle(Theme.danger)
                default:
                    EmptyView()
                }
            }
            .padding(16)
        }
        .onAppear(perform: reload)
        .onDisappear { test.cancel() }
        .onChange(of: microphone) { if test.isListening { test.cancel() } }
        .onChange(of: language) { if test.isListening { test.cancel() } }
    }

    private var microphoneDetail: String {
        if microphone.isEmpty { return "Following macOS: \(systemDefault?.name ?? "no input device")." }
        return inputs.contains { $0.uid == microphone } ? "Always this one, whatever macOS uses." : "Not plugged in; using the system default for now."
    }

    private func reload() {
        inputs = AudioInput.all()
        systemDefault = AudioInput.systemDefault()
    }
}

/// A row of bars that fill with the voice, green to amber.
private struct LevelBars: View {
    let level: Double
    private let count = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                let lit = Double(index) / Double(count) < level
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? (index < count * 2 / 3 ? Theme.success : Theme.warning) : Theme.selected)
                    .frame(width: 5, height: 14)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - Git

private struct GitPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: GitAccount?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.gitAccounts) { account in
                GitAccountRow(account: account, projects: model.projects.filter { $0.gitAccountID == account.id }) {
                    editing = account
                }
            }
            Button {
                editing = GitAccount(label: "", name: "", email: "", sshKeyPath: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(SettingsPane.git.tint)
                    Text("Add Account…").foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .font(.system(size: 13))
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(item: $editing) { account in
            GitAccountEditor(account: account)
        }
    }
}

// MARK: - Paths

private struct PathsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.agentChoices) { agent in
            AgentPathEntry(agent: agent)
        }
        Text("Leave a path empty to find the CLI on your login shell's PATH. Agents switched off in Settings → Agents aren't listed. Sign in from Settings → Agents.")
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The stored custom path for one agent's CLI.
private struct AgentPathEntry: View {
    let agent: AgentKind
    @AppStorage private var path: String

    init(agent: AgentKind) {
        self.agent = agent
        _path = AppStorage(wrappedValue: "", AppSettings.pathKey(for: agent))
    }

    var body: some View {
        AgentPathSection(agent: agent, path: $path)
    }
}

private struct AgentPathSection: View {
    let agent: AgentKind
    @Binding var path: String
    @State private var version: String?
    @State private var failed = false
    @State private var checking = false

    private var found: URL? {
        path.isEmpty ? ExecutableLocator.find(agent.executableName) : URL(fileURLWithPath: path)
    }

    var body: some View {
        SettingsSection(title: agent.displayName) {
            SettingsRow(title: "Found at", detail: nil, divider: false) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(found.map { FileManager.default.isExecutableFile(atPath: $0.path) } == true ? Theme.success : Theme.danger)
                        .frame(width: 7, height: 7)
                    Text(found.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not found")
                        .font(Theme.Font.toolTarget)
                        .foregroundStyle(found == nil ? Theme.danger : Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            SettingsRow(title: "Custom path", detail: "Only if the CLI lives somewhere unusual.") {
                TextField("", text: $path, prompt: Text("Automatic"))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.toolTarget)
                    .frame(width: 260)
            }
            SettingsRow(title: "Version", detail: nil) {
                HStack(spacing: 8) {
                    if checking { ProgressView().controlSize(.small) }
                    if let version {
                        Text(version)
                            .font(Theme.Font.toolTarget)
                            .foregroundStyle(failed ? Theme.danger : Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                    Button("Check", action: check).disabled(checking)
                }
            }
        }
        .task { check() }
        .onChange(of: path) { version = nil }
    }

    private func check() {
        checking = true
        let runner = AgentRunner(locator: ExecutableLocator(overrides: [agent: path]))
        let agent = agent
        Task.detached {
            let result: (String, Bool)
            do {
                let output = try runner.capture(agent, arguments: ["--version"], timeout: 10)
                result = (output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? output, false)
            } catch {
                result = (error.localizedDescription, true)
            }
            await MainActor.run {
                version = result.0
                failed = result.1
                checking = false
            }
        }
    }
}
