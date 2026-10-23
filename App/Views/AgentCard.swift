import MountagentDeskKit
import SwiftUI

/// One agent's account in Settings → Agents, in three tiers: who (agent, plan, account,
/// CLI version), how much is left (a ring per plan limit), and what Mountagent Desk spent, with
/// the CLI's longer usage insights folded away.
struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let kind: AgentKind
    /// Setup terminals open over the Settings window, where the card lives.
    private let host = AppModel.SetupTask.Host.settings
    @State private var showsInsights = false

    private var account: AgentAccount? { model.account(kind) }
    private var enabled: Bool { model.isEnabled(kind) }
    private var ready: Bool { enabled && account?.isInstalled == true && account?.loggedIn == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)
            if enabled, kind == .copilot {
                divider
                CopilotAccountPicker()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            if !enabled {
                EmptyView()
            } else if ready {
                divider
                limits
                    .padding(14)
                divider
                footer
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if showsInsights, kind == .claude, let notes = model.planUsage?.notes, !notes.isEmpty {
                    insights(notes)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            } else if account != nil {
                divider
                setupPrompt
                    .padding(14)
            } else {
                divider
                placeholder("Checking \(kind.displayName)…")
                    .padding(14)
            }
        }
        .opacity(enabled ? 1 : 0.85)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        .animation(.snappy(duration: 0.2), value: showsInsights)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(symbol: kind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background((enabled ? kind.tint : Theme.textTertiary).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(kind.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let plan = account?.plan, ready {
                        Text(plan)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(kind.tint)
                            .padding(.horizontal, 7)
                            .frame(height: 17)
                            .background(kind.tint.opacity(0.14), in: Capsule())
                    }
                }
                subtitle
            }
            Spacer(minLength: 8)
            if ready { trailing }
            Toggle(kind.displayName, isOn: Binding(get: { enabled }, set: { model.setEnabled(kind, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // At least one agent stays on.
                .disabled(enabled && model.agentChoices.count == 1)
                .help(enabled ? "Turn \(kind.displayName) off: hidden from the agent pickers" : "Turn \(kind.displayName) on")
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if !enabled {
            Text("Off · \(kind.vendor)'s coding agent, run through its CLI")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        } else if let account {
            HStack(spacing: 5) {
                Circle()
                    .fill(account.loggedIn ? Theme.success : account.isInstalled ? Theme.warning : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                Text(statusText(account))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
        } else {
            Text("Checking…").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func statusText(_ account: AgentAccount) -> String {
        if !account.isInstalled { return "Not installed" }
        if !account.loggedIn { return "Installed, not signed in" }
        let who = [account.email, account.organization].compactMap { $0 }.joined(separator: " · ")
        return who.isEmpty ? "Signed in" + (account.authMethod.map { " with \($0)" } ?? "") : who
    }

    /// Version chip (or Update), then the menu holding everything else.
    private var trailing: some View {
        HStack(spacing: 6) {
            if account?.updateAvailable == true {
                Button {
                    model.update(kind, from: host)
                } label: {
                    Label("Update to \(account?.latestVersion ?? "latest")", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
            } else if let version = account?.version {
                Text("v\(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Theme.hover, in: Capsule())
                    .help(account?.executable.map { "CLI at \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? "")
            }
            Menu {
                Button("Open Usage in Browser", systemImage: "safari") { NSWorkspace.shared.open(AgentSetup.usagePage(for: kind)) }
                if let path = account?.executable {
                    Button("Show CLI in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).resolvingSymlinksInPath()])
                    }
                }
                Button("Update CLI", systemImage: "arrow.down.circle") { model.update(kind, from: host) }
                if kind == .cursor, model.showsCursorUsage {
                    Button("Stop Reading Cursor Usage", systemImage: "eye.slash") { model.setShowsCursorUsage(false) }
                }
                if AgentSetup.logoutCommand(for: kind, executable: nil) != nil {
                    Divider()
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.signOut(kind, from: host) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
            }
            .chipMenu()
        }
        .controlSize(.small)
    }

    // MARK: Limits

    @ViewBuilder
    private var limits: some View {
        switch kind {
        case .claude:
            if let usage = model.planUsage {
                UsageRings(limits: usage.limits, updated: usage.fetchedAt)
            } else {
                placeholder("Reading usage…")
            }
        case .cursor:
            cursorLimits
        case .codex where model.codexUsage != nil:
            if let usage = model.codexUsage { UsageRings(limits: usage.limits, updated: usage.fetchedAt) }
        case .copilot where model.copilotUsage != nil:
            if let usage = model.copilotUsage?.usage {
                VStack(alignment: .leading, spacing: 8) {
                    if !usage.limits.isEmpty { UsageRings(limits: usage.limits, updated: usage.fetchedAt) }
                    ForEach(usage.notes, id: \.self) { Text($0).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                }
            }
        case .codex, .antigravity, .copilot:
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Theme.textTertiary)
                Text("\(kind.displayName)'s CLI doesn't report plan limits. Signed in with \(account?.authMethod ?? "an account").")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Usage Page") { NSWorkspace.shared.open(AgentSetup.usagePage(for: kind)) }
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var cursorLimits: some View {
        if !model.showsCursorUsage {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan usage is off")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(CursorUsageMeters.keychainNote)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show Usage") { model.setShowsCursorUsage(true) }
                    .controlSize(.small)
            }
        } else if let usage = model.cursorUsage {
            VStack(alignment: .leading, spacing: 10) {
                UsageRings(limits: usage.limits, updated: usage.fetchedAt)
                if let used = usage.usedUSD, let limit = usage.limitUSD, limit > 0 {
                    Text("\(used.formatted(.currency(code: "USD"))) of \(limit.formatted(.currency(code: "USD"))) included usage this cycle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if let problem = model.cursorUsageProblem {
                    Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.warning)
                }
            }
        } else if let problem = model.cursorUsageProblem {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Try Again") { model.refreshCursorUsage(userInitiated: true) }
                    .controlSize(.small)
            }
        } else {
            placeholder("Reading usage…")
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.Font.ui).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Footer

    /// "Via Mountagent Desk  Today $1.20 · 7 days $8.40 · 30 days $21" and the folded extras.
    private var footer: some View {
        HStack(spacing: 10) {
            Text("Via Mountagent Desk")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                stat("Today", model.ledger.total(for: kind, lastDays: 1))
                dot
                stat("7 days", model.ledger.total(for: kind, lastDays: 7))
                dot
                stat("30 days", model.ledger.total(for: kind, lastDays: 30))
            }
            Spacer(minLength: 8)
            if kind == .claude, model.planUsage?.notes.isEmpty == false {
                Button {
                    showsInsights.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Text("Insights")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showsInsights ? 90 : 0))
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .hoverHighlight(cornerRadius: Theme.Radius.chip)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dot: some View {
        Text("·").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
    }

    private func stat(_ title: String, _ entry: UsageLedger.Entry) -> some View {
        let tokens = entry.totalTokens.formatted(.number.notation(.compactName))
        let value = entry.hasCost ? entry.costUSD.formatted(.currency(code: "USD").precision(.fractionLength(2))) : "\(tokens) tok"
        return HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.textSecondary)
            Text(value).fontWeight(.semibold).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(Theme.Font.caption)
        .help("\(entry.turns) turn\(entry.turns == 1 ? "" : "s") · \(tokens) tokens")
    }

    /// The CLI's "Last 24h · 798 requests · 44 sessions" blocks, as compact rows.
    private func insights(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.self) { note in
                let heading = note.hasPrefix("Last ")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !heading {
                        Circle().fill(Theme.textTertiary).frame(width: 3, height: 3).offset(y: -2)
                    }
                    Text(note)
                        .font(heading ? .system(size: 11.5, weight: .semibold) : Theme.Font.caption)
                        .foregroundStyle(heading ? Theme.textPrimary : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, heading && note != notes.first ? 6 : 0)
                .padding(.leading, heading ? 0 : 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Setup

    private var setupPrompt: some View {
        let installed = account?.isInstalled == true
        return HStack(spacing: 12) {
            Text(kind == .copilot && installed
                ? "Pick a GitHub account with Copilot above, or sign in through your browser."
                : installed
                ? "Sign in through your browser to use \(kind.displayName) here."
                : "Mountagent Desk runs \(kind.displayName) through its CLI. Install it, then sign in through your browser.")
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(installed ? "Sign In…" : "Install & Sign In…") { model.setUp(kind, from: host) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
        }
    }
}

/// Which GitHub account Copilot runs as: one of those signed in to `gh` (its token is handed
/// to each turn), or Copilot's own `copilot login`.
private struct CopilotAccountPicker: View {
    @Environment(AppModel.self) private var model
    @State private var logins: [String] = []

    var body: some View {
        HStack(spacing: 10) {
            Text("GitHub account")
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("GitHub account", selection: Binding(get: { model.copilotAccount }, set: { model.setCopilotAccount($0) })) {
                Text("Copilot's own sign-in").tag(String?.none)
                ForEach(logins, id: \.self) { login in
                    Text(login).tag(String?.some(login))
                }
                if let current = model.copilotAccount, !logins.contains(current) {
                    Text(current).tag(String?.some(current))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Copilot runs as this account, with its GitHub CLI (gh) sign-in. The account needs a Copilot plan; each prompt uses a premium request.")
        }
        .task { logins = await Task.detached { GitHubCLI.accounts() }.value }
        CopilotTokenField()
    }
}

/// An optional token made for Copilot alone, kept in the keychain.
private struct CopilotTokenField: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("Copilot token")
                .font(Theme.Font.ui)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            SecureField("Token", text: $token, prompt: Text(model.hasCopilotToken ? "Saved in Keychain" : "Optional"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { save() }
            if model.hasCopilotToken {
                Button("Forget") { model.saveCopilotToken(nil) }
            } else {
                Button("Save", action: save).disabled(token.isEmpty)
            }
        }
        .help("A fine-grained GitHub token with only the \u{201C}Copilot Requests\u{201D} permission. Copilot then runs with it instead of the GitHub CLI's sign-in token, which could also push to your repositories or add SSH keys.")
    }

    private func save() {
        model.saveCopilotToken(token)
        token = ""
    }
}

/// Plan limits as rings side by side: percent inside, name and reset under.
private struct UsageRings: View {
    let limits: [PlanUsage.Limit]
    let updated: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan usage")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("Updated \(updated.formatted(.relative(presentation: .named)))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(limits, id: \.name) { limit in
                    UsageRing(limit: limit)
                }
            }
        }
    }
}

private struct UsageRing: View {
    let limit: PlanUsage.Limit

    var body: some View {
        let color = Theme.level(percent: limit.percent)
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.selected, lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, Double(limit.percent) / 100)))
                    .stroke(color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(limit.percent)%")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let reset = UsageMeter.resetLabel(for: limit) {
                    Text(reset)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .animation(.easeOut(duration: 0.3), value: limit.percent)
    }
}

/// Cursor's current-cycle meters in the sidebar, or the switch that turns them on
/// (reading Cursor's sign-in token makes macOS show a keychain prompt, so it is opt-in).
struct CursorUsageMeters: View {
    @Environment(AppModel.self) private var model

    static let keychainNote = "Reads the sign-in token cursor-agent keeps in your keychain; macOS asks you first."

    var body: some View {
        if model.needsSetup(.cursor) {
            Button("Set up Cursor…") { model.setUp(.cursor) }
                .buttonStyle(.link)
                .font(Theme.Font.ui)
        } else if !model.showsCursorUsage {
            Button("Show Cursor usage…") { model.setShowsCursorUsage(true) }
                .buttonStyle(.link)
                .font(Theme.Font.ui)
                .help(Self.keychainNote)
        } else if let usage = model.cursorUsage {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(usage.limits.prefix(2)), id: \.name) { limit in
                    UsageMeter(limit: limit)
                }
                if let problem = model.cursorUsageProblem {
                    Text(problem).font(Theme.Font.caption).foregroundStyle(Theme.warning)
                }
            }
        } else if let problem = model.cursorUsageProblem {
            VStack(alignment: .leading, spacing: 4) {
                Text(problem)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { model.refreshCursorUsage(userInitiated: true) }
                    .buttonStyle(.link)
                    .font(Theme.Font.caption)
            }
        } else {
            Text("Reading usage…")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// "Session (5hr) ········ 54%" with a bar and "Resets in 2h", as in Claude Code's panel.
struct UsageMeter: View {
    let limit: PlanUsage.Limit

    private var color: Color {
        Theme.level(percent: limit.percent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(limit.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(limit.percent)%")
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
            .font(.system(size: 12.5))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.selected)
                    Capsule().fill(color)
                        .frame(width: max(5, proxy.size.width * min(1, Double(limit.percent) / 100)))
                }
            }
            .frame(height: 5)
            if let reset = resetLabel {
                Text(reset)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.3), value: limit.percent)
    }

    private var resetLabel: String? { Self.resetLabel(for: limit) }

    static func resetLabel(for limit: PlanUsage.Limit) -> String? {
        if let date = limit.resetsAt {
            let seconds = date.timeIntervalSinceNow
            guard seconds > 0 else { return "Resetting now" }
            let minutes = Int(seconds / 60)
            if minutes < 60 { return "Resets in \(max(1, minutes))m" }
            let hours = minutes / 60
            if hours < 24 { return "Resets in \(hours)h" }
            return "Resets in \(hours / 24)d"
        }
        return limit.resetText.map { "Resets \($0)" }
    }
}

/// The terminal sheet for installing, signing in, signing out or updating an agent.
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let task: AppModel.SetupTask
    /// Replaces the default (re-checking the agents) for other kinds of setup.
    var onDone: (() -> Void)?
    @State private var exitCode: Int32??
    // Sign-ins that may ask for a pasted code (Antigravity): the link, the code to pass in.
    @State private var input = TerminalInput()
    @State private var signInLink: URL?
    @State private var code = ""
    @State private var codeSent = false
    /// The CLI is asking for the code right now.
    @State private var asksForCode = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(symbol: task.symbolName ?? task.kind?.symbolName ?? "terminal")
                    .foregroundStyle(task.kind?.tint ?? Theme.textPrimary)
                Text(task.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let exitCode {
                    Label(exitCode == 0 ? "Finished" : "Exited with code \(exitCode.map(String.init) ?? "?")",
                          systemImage: exitCode == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(Theme.Font.ui)
                        .foregroundStyle(exitCode == 0 ? Theme.success : Theme.warning)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            Text(task.hint ?? "A browser window opens for signing in. Come back here when it says you're done; if it shows a one-time code, enter it on the GitHub or sign-in page, and press Return here when asked.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if let flow = task.signIn {
                signInBar(flow)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            SetupTerminal(command: task.command, dark: colorScheme == .dark, input: input, onOutput: task.signIn.map { flow in
                { output in watch(output, flow: flow) }
            }) { code in
                exitCode = .some(code)
            }
            .padding(10)
            .background(TerminalTheme.current.background(dark: colorScheme == .dark))

            HStack {
                Text(task.command)
                    .font(Theme.Font.toolTarget)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                // A CLI that stays open after signing in (Antigravity) is finished from here.
                Button(exitCode != nil ? "Done" : task.signIn != nil ? "Finish" : "Cancel") {
                    if let onDone { onDone() } else { model.setupFinished() }
                }
                    .keyboardShortcut(exitCode == nil ? .cancelAction : .defaultAction)
            }
            .padding(12)
        }
        .frame(width: 680, height: task.signIn == nil ? 460 : 520)
        .background(Theme.background)
    }

    /// Notes the sign-in link (the CLI opens the browser itself; the button opens it again)
    /// and whether it is waiting for a code.
    private func watch(_ output: String, flow: AgentSetup.SignInFlow) {
        if signInLink == nil {
            signInLink = AgentSetup.link(in: output, prefix: flow.linkPrefix)
        }
        asksForCode = output.contains(flow.codePrompt)
    }

    private func sendCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, asksForCode else { return }
        input.send(trimmed + "\r")
        codeSent = true
        code = ""
    }

    @ViewBuilder
    private func signInBar(_ flow: AgentSetup.SignInFlow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let signInLink {
                    Image(systemName: "safari").foregroundStyle(Theme.action)
                    Text(codeSent ? "Code sent. Waiting for \(task.kind?.displayName ?? "the CLI")…" : "Sign-in page opened in your browser.")
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(signInLink)
                    } label: {
                        Label("Open Sign-in Page", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the sign-in link…")
                }
                Spacer(minLength: 0)
            }
            .font(Theme.Font.ui)
            .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                TextField("Paste the authorization code from the browser", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Font.toolTarget)
                    .onSubmit(sendCode)
                Button("Send", action: sendCode)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.action)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || !asksForCode)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
