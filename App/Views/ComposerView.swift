import MountagentDeskKit
import SwiftUI

/// Floating composer: text, then a footer of chips (attach, agent, model, access) and the
/// send button. A pill above it shows what the agent is doing.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.fullWidthChatKey) private var fullWidthChat = true
    let session: ChatSession
    @Binding var text: String
    @State private var attachments: [String] = []
    @State private var images: [URL] = []
    @State private var pasteRouter = ComposerPasteRouter()
    @State private var dropTargeted = false
    @FocusState private var focused: Bool
    @Environment(\.isActivePane) private var isActivePane
    @Environment(\.paneIndex) private var paneIndex
    @State private var hovering = false
    @State private var dictation = SpeechDictation()
    @AppStorage(AppSettings.dictationLanguageKey) private var dictationLanguage = AppSettings.defaultDictationLanguage
    @AppStorage(AppSettings.dictationSendsKey) private var dictationSends = false
    @AppStorage(AppSettings.dictationMicrophoneKey) private var dictationMicrophone = ""

    private var isRunning: Bool { model.isRunning(session.id) }
    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }
    /// While the agent works, sending queues the message for the end of its turn.
    private var canSend: Bool { hasContent }
    /// The button stops the agent when there's nothing to queue.
    private var stops: Bool { isRunning && !hasContent }
    private var project: Project? { model.project(session.projectID) }

    var body: some View {
        VStack(spacing: 8) {
            if let matches = PromptTemplate.matches(for: text, in: model.promptTemplates), !matches.isEmpty {
                TemplateSuggestions(templates: Array(matches.prefix(6))) { text = $0.text }
                    .transition(.opacity)
            }
            if let waiting = model.queued[session.id] {
                QueuedPill(text: waiting.text) {
                    if let message = model.cancelQueued(in: session.id) {
                        text = message.text + (text.isEmpty ? "" : "\n\n" + text)
                        attachments = message.attachments + attachments
                        images = message.images + images
                    }
                }
                .transition(.opacity)
            }
            if isRunning {
                ActivityPill(session: session, waitingForApproval: model.hasPendingPermission(session.id))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if model.needsSetup(session.agent) {
                SetupBanner(agent: session.agent, installed: model.account(session.agent)?.isInstalled == true)
            }
            dictationProblem
            if !model.isEnabled(session.agent) {
                DisabledAgentBanner(agent: session.agent)
            }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    if !attachments.isEmpty || !images.isEmpty {
                        attachmentStrip
                    }
                    editor
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                Rectangle()
                    .fill(focused ? session.agent.tint.opacity(0.25) : Theme.hairline)
                    .frame(height: 1)

                footer
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }
            .background(Theme.elevated, in: composerShape)
            .overlay(composerShape.strokeBorder(dropTargeted ? Theme.accent : borderColor, lineWidth: dropTargeted || dictation.isListening ? 2 : 1))
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
            // A soft ring in the agent's color while typing, like Claude Code's prompt box;
            // while dictating it glows red and breathes with the voice.
            .shadow(color: ringColor, radius: dictation.isListening ? 4 + 10 * dictation.level : focused ? 6 : 8, y: focused || dictation.isListening ? 0 : 2)
            .animation(.easeOut(duration: 0.1), value: dictation.level)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: focused)
            .animation(.easeOut(duration: 0.15), value: hovering)

            StatusLine(session: session, project: project, result: model.lastResults[session.id])
        }
        .animation(.snappy(duration: 0.2), value: isRunning)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: Theme.chatMaxWidth(fullWidth: fullWidthChat))
        .frame(maxWidth: .infinity)
        // The transcript scrolls under this area: keep it opaque, and fade the text out
        // just above it instead of letting lines touch the box.
        .background {
            Theme.background
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                        .offset(y: -28)
                        .allowsHitTesting(false)
                }
        }
        .onAppear {
            if isActivePane { focused = true }
            pasteRouter.onPaste = { pasted in add(pasted) }
            pasteRouter.install()
        }
        .onDisappear {
            pasteRouter.uninstall()
            dictation.cancel()
        }
        .onChange(of: focused) { _, isFocused in
            pasteRouter.isFocused = isFocused
            // Typing in a pane focuses it.
            if isFocused, !isActivePane { model.focusPane(paneIndex) }
        }
        .onChange(of: isActivePane) { _, active in
            if active { focused = true }
        }
    }

    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
    }

    private var borderColor: Color {
        if dictation.isListening { return Theme.danger.opacity(0.55 + 0.45 * dictation.level) }
        if focused { return session.agent.tint.opacity(0.85) }
        return hovering ? Theme.ink(0.24) : Theme.stroke
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Ask \(session.agent.shortName)…")
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .focused($focused)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textPrimary)
                .tint(session.agent.tint)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 20, maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                    send()
                    return .handled
                }
        }
        .font(Theme.Font.body)
    }

    /// Narrow panes get icon-only chips rather than a footer wider than the box.
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            footerContent
            footerContent.environment(\.compactChips, true)
        }
    }

    private var footerContent: some View {
        HStack(spacing: 2) {
            Button(action: attachFiles) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Attach files from the project")

            agentChip
            modelChip
            effortChip
            accessChip
            templatesChip

            Spacer(minLength: 8)
            micButton
            sendButton
        }
    }

    private var ringColor: Color {
        if dictation.isListening { return Theme.danger.opacity(0.25 + 0.35 * dictation.level) }
        return focused ? session.agent.tint.opacity(0.22) : .black.opacity(0.06)
    }

    /// Click to talk, click again (or pause, with auto-send) to stop; hold for the language.
    private var micButton: some View {
        Menu {
            Picker("Language", selection: $dictationLanguage) {
                ForEach(SpeechDictation.languages, id: \.id) { language in
                    Text(language.title).tag(language.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Microphone", selection: $dictationMicrophone) {
                Text("System Default" + (AudioInput.systemDefault().map { " (\($0.name))" } ?? "")).tag("")
                ForEach(AudioInput.all()) { input in
                    Text(input.name).tag(input.uid)
                }
            }
            Toggle("Send When I Stop Talking", isOn: $dictationSends)
            Divider()
            SettingsLink { Text("Voice Settings…") }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: dictation.isListening ? "waveform" : "mic")
                    .font(.system(size: 12, weight: .medium))
                    .symbolEffect(.variableColor.iterative, isActive: dictation.isListening)
                Text(SpeechDictation.short(of: dictationLanguage))
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(dictation.isListening ? Theme.danger : Theme.textSecondary)
            .padding(.horizontal, 5)
            .frame(height: 24)
            .background(dictation.isListening ? Theme.danger.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .hoverHighlight(cornerRadius: Theme.Radius.chip)
        } primaryAction: {
            toggleDictation()
        }
        .chipMenu()
        .padding(.trailing, 4)
        .help(dictation.isListening
              ? "Stop dictating (⇧⌘D)"
              : "Dictate in \(SpeechDictation.title(of: dictationLanguage)) (⇧⌘D). Hold for language and auto-send.")
        .background {
            if isActivePane {
                Button("Dictate", action: toggleDictation)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .hidden()
            }
        }
    }

    @ViewBuilder
    private var dictationProblem: some View {
        if dictation.isListening, dictation.hearsNothing {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.xmark").foregroundStyle(Theme.warning)
                Text("No sound from \(dictation.microphone ?? "the microphone"). Hold the mic button to pick another one.")
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(Theme.Font.ui)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        switch dictation.status {
        case .denied(let message), .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "mic.slash").foregroundStyle(Theme.danger)
                Text(message).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if case .denied = dictation.status {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .controlSize(.small)
                }
                Button { dictation.dismissProblem() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.Font.ui)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        default:
            EmptyView()
        }
    }

    /// The transcript goes after whatever was already typed, and is rewritten as the
    /// recognizer revises it.
    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
            return
        }
        let typed = text
        let separator = typed.isEmpty || typed.hasSuffix(" ") || typed.hasSuffix("\n") ? "" : " "
        focused = true
        Task {
            await dictation.start(language: dictationLanguage, microphone: dictationMicrophone, onText: { transcript in
                text = typed + separator + transcript
            }, onSilence: dictationSends ? { send() } : nil)
        }
    }

    private var agentChip: some View {
        Menu {
            Picker("Agent", selection: Binding(get: { session.agent }, set: { model.setAgent($0, for: session.id) })) {
                // A session may still be on an agent that has since been switched off.
                ForEach(AgentKind.allCases.filter { model.isEnabled($0) || $0 == session.agent }) { agent in
                    Label { Text(agent.displayName) } icon: { Image(symbol: agent.symbolName) }.tag(agent)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text("Switching hands the other agent the turns it missed.")
        } label: {
            ChipLabel(title: session.agent.shortName, symbol: session.agent.symbolName, tint: session.agent.tint)
        }
        .chipMenu()
        .disabled(isRunning)
        .help("Agent for the next message")
    }

    @ViewBuilder
    private var modelChip: some View {
        switch session.agent {
        case .claude:
            let models = AgentKind.claude.builtInModels
            Menu {
                Picker("Model", selection: Binding(get: { session.model }, set: { model.setModel($0, for: session.id) })) {
                    ForEach(models) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                ChipLabel(title: models.first { $0.id == session.model }?.name ?? session.model ?? "Default")
            }
            .chipMenu()
            .help("Model")
        case .cursor:
            let families = model.cursorFamilies
            let current = model.cursorFamily(for: session)
            Menu {
                ForEach(families) { family in
                    Button {
                        model.setCursorFamily(family, for: session.id)
                    } label: {
                        if family.id == current?.id {
                            Label(family.name, systemImage: "checkmark")
                        } else {
                            Text(family.name)
                        }
                    }
                }
                Divider()
                Button("Reload Cursor Models") { model.refreshCursorModels() }
            } label: {
                ChipLabel(title: current?.name ?? session.model ?? "Auto")
            }
            .chipMenu()
            .help("Model")
        case .codex, .antigravity, .copilot:
            let models = model.models(for: session.agent)
            Menu {
                Picker("Model", selection: Binding(get: { session.model }, set: { model.setModel($0, for: session.id) })) {
                    ForEach(models) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.inline)
                if session.agent == .codex {
                    Divider()
                    Button("Reload Codex Models") { model.refreshCodexModels() }
                } else if session.agent == .copilot {
                    Divider()
                    Button("Reload Copilot Models") { model.refreshCopilotModels() }
                }
            } label: {
                ChipLabel(title: models.first { $0.id == session.model }?.name ?? session.model ?? models.first?.name ?? "Default")
            }
            .chipMenu()
            .help("Model")
        }
    }

    /// Low … Max. Claude takes any level; for Cursor the levels are the variants the
    /// chosen model has, plus a Fast switch when it has fast variants.
    @ViewBuilder
    private var effortChip: some View {
        switch session.agent {
        case .claude, .codex, .antigravity, .copilot:
            Menu {
                Picker("Effort", selection: Binding(get: { session.effort }, set: { model.setEffort($0, for: session.id) })) {
                    Text("Default").tag(String?.none)
                    ForEach(model.efforts(for: session), id: \.self) { level in
                        Text(Effort.name(level)).tag(String?.some(level))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                ChipLabel(title: session.effort.map(Effort.name) ?? "Effort", symbol: "gauge.with.dots.needle.50percent")
            }
            .chipMenu()
            .help("Reasoning effort")
        case .cursor:
            if let family = model.cursorFamily(for: session), family.hasEffort || family.hasFast {
                let variant = family.variant(for: session.models[.cursor])
                Menu {
                    if family.hasEffort {
                        Picker("Effort", selection: Binding(get: { variant?.effort ?? family.defaultEffort }, set: { model.setEffort($0, for: session.id) })) {
                            ForEach(family.efforts, id: \.self) { effort in
                                Text(effort == family.defaultEffort ? "\(Effort.name(effort)) (default)" : Effort.name(effort)).tag(effort)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    if family.hasFast {
                        Divider()
                        Toggle("Fast", isOn: Binding(
                            get: { variant?.fast ?? false },
                            set: { model.setEffort(variant?.effort ?? family.defaultEffort, fast: $0, for: session.id) }
                        ))
                    }
                } label: {
                    ChipLabel(
                        title: effortTitle(variant: variant, family: family),
                        symbol: variant?.fast == true ? "bolt" : "gauge.with.dots.needle.50percent"
                    )
                }
                .chipMenu()
                .help("Reasoning effort and speed")
            }
        }
    }

    private func effortTitle(variant: ModelFamily.Variant?, family: ModelFamily) -> String {
        let effort = family.hasEffort ? Effort.name(variant?.effort ?? family.defaultEffort) : nil
        let fast = variant?.fast == true ? "Fast" : nil
        return [effort, fast].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Standard"
    }

    private var accessChip: some View {
        Menu {
            Picker("Access", selection: Binding(get: { session.access }, set: { model.setAccess($0, for: session.id) })) {
                ForEach(AccessLevel.allCases) { level in
                    Label(level.displayName, systemImage: level.symbolName).tag(level)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(
                title: session.access.shortName,
                symbol: session.access.symbolName,
                tint: session.access == .fullAccess ? Theme.warning : nil
            )
        }
        .chipMenu()
        .help("What the agent may do without asking")
    }

    /// Kept prompts: insert one, keep the box's text as one, or drop one.
    private var templatesChip: some View {
        Menu {
            ForEach(model.promptTemplates) { template in
                Button(template.title) { insert(template) }
            }
            Divider()
            Button("Save Text as Prompt…") { model.saveAsTemplate(text) }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !model.promptTemplates.isEmpty {
                Menu("Delete Prompt") {
                    ForEach(model.promptTemplates) { template in
                        Button(template.title) { model.savePromptTemplates(model.promptTemplates.filter { $0.id != template.id }) }
                    }
                }
            }
        } label: {
            ChipLabel(title: "Prompts", symbol: "text.badge.star")
        }
        .chipMenu()
        .help("Kept prompts (or type / and part of a name)")
    }

    private func insert(_ template: PromptTemplate) {
        let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = current.isEmpty || current.hasPrefix("/") ? template.text : text + (text.hasSuffix("\n") ? "" : "\n\n") + template.text
        focused = true
    }

    private var sendButton: some View {
        Button {
            if stops { model.stop(session.id) } else { send() }
        } label: {
            Image(systemName: stops ? "stop.fill" : isRunning ? "text.append" : "arrow.up")
                .font(.system(size: stops ? 10 : 13, weight: .bold))
                .foregroundStyle(canSend || isRunning ? Theme.background : Theme.textTertiary)
                .frame(width: 24, height: 24)
                .background(stops ? Theme.textPrimary : canSend ? session.agent.tint : Theme.selected, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !isRunning)
        .help(stops ? "Stop (⌘.)" : isRunning ? "Send when this turn ends (Return)" : "Send (Return)")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(images, id: \.self) { url in
                    ImageThumbnail(url: url, size: 52)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                images.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                        .padding(.top, 5)
                        .padding(.trailing, 5)
                }
                ForEach(attachments, id: \.self) { path in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(Theme.textTertiary)
                        Text(project?.displayPath(path) ?? path)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textPrimary)
                        Button {
                            attachments.removeAll { $0 == path }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(Theme.Font.caption)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                }
            }
        }
    }

    private func send() {
        guard canSend else { return }
        // Late words from the recognizer must not land in the emptied box.
        dictation.cancel()
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { message = images.count == 1 ? "Look at this image." : "Look at these images." }
        model.submit(message, attachments: attachments, images: images, in: session.id)
        text = ""
        attachments = []
        images = []
    }

    /// Images become thumbnails; other files are mentioned by path, as with the paperclip.
    private func add(_ pasted: ImageAttachments.Pasted) {
        for url in pasted.images where !images.contains(url) { images.append(url) }
        for url in pasted.files {
            let path = project?.agentPath(for: url) ?? url.path
            if !attachments.contains(path) { attachments.append(path) }
        }
        focused = true
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    let pasted: ImageAttachments.Pasted = ImageAttachments.isImage(url)
                        ? .init(images: ImageAttachments.importImage(at: url).map { [$0] } ?? [])
                        : .init(files: [url])
                    Task { @MainActor in add(pasted) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in
                        if let saved = ImageAttachments.save(image) { add(.init(images: [saved])) }
                    }
                }
            }
        }
        return handled
    }

    private func attachFiles() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = project.url
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = project.additionalPaths.isEmpty ? "" : "Files from any of the project's folders can be attached."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = project.agentPath(for: url)
            if !attachments.contains(path) { attachments.append(path) }
        }
    }
}

/// Shown instead of failing on send when the agent's CLI is missing or signed out.
/// Kept prompts matching what follows `/` in the box; a click puts one in its place.
private struct TemplateSuggestions: View {
    let templates: [PromptTemplate]
    let pick: (PromptTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(templates) { template in
                Button {
                    pick(template)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.title)
                            .font(Theme.Font.ui.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(template.text)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: Theme.Radius.row)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// The message waiting for the turn to end; the button takes it back into the box.
private struct QueuedPill: View {
    let text: String
    let takeBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.append")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Next: \(text)")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Edit", action: takeBack)
                .buttonStyle(.plain)
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .help("Take the message back into the box; it won't be sent by itself")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

private struct SetupBanner: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    let installed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: installed ? "person.crop.circle.badge.exclamationmark" : "arrow.down.circle")
                .foregroundStyle(Theme.warning)
            Text(installed ? "\(agent.displayName) isn't signed in." : "\(agent.displayName) isn't installed on this Mac.")
                .foregroundStyle(Theme.textPrimary)
            Button(installed ? "Sign In…" : "Install & Sign In…") { model.setUp(agent) }
                .buttonStyle(.link)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .floatingSurface(cornerRadius: 14)
    }
}

/// "Claude is working · 0:42" while a turn runs.
private struct ActivityPill: View {
    let session: ChatSession
    let waitingForApproval: Bool
    @State private var start = Date()

    var body: some View {
        HStack(spacing: 8) {
            if waitingForApproval {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.warning)
                Text("Waiting for your approval")
                    .foregroundStyle(Theme.textPrimary)
            } else {
                ProgressView()
                    .controlSize(.mini)
                Text("\(session.agent.shortName) is working")
                    .foregroundStyle(Theme.textPrimary)
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(start).rounded()).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("⌘. to stop")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .floatingSurface(cornerRadius: 14)
        .onAppear { start = .now }
    }
}

/// Folder, session state and the last turn's cost under the composer.
private struct StatusLine: View {
    let session: ChatSession
    let project: Project?
    let result: TurnResult?

    var body: some View {
        HStack(spacing: 6) {
            Spacer()
            Text(details.joined(separator: " · "))
        }
        .font(Theme.Font.caption)
        .monospacedDigit()
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
    }

    private var details: [String] {
        var parts: [String] = []
        if session.agentSessionIDs[session.agent] != nil { parts.append("resumes") }
        guard let result else { return parts }
        if let ms = result.durationMs {
            parts.append(Duration.milliseconds(ms).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        }
        if let input = result.inputTokens, let output = result.outputTokens {
            parts.append("\((input + output).formatted(.number.notation(.compactName))) tok")
        }
        if let cost = result.costUSD {
            parts.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
        }
        return parts
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension AccessLevel {
    var shortName: String {
        switch self {
        case .readOnly: "Read only"
        case .editFiles: "Ask"
        case .fullAccess: "Full access"
        }
    }
}

/// A rounded image preview; click opens the full image in Preview.
struct ImageThumbnail: View {
    let url: URL
    var size: CGFloat = 52
    /// Keep the image's proportions (transcript) instead of a square crop (composer).
    var fitsWithin: CGSize?

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Group {
                if let image = NSImage(contentsOf: url) {
                    if let box = fitsWithin {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: box.width, maxHeight: box.height)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                    }
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: size, height: size)
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help("Open \(url.lastPathComponent)")
    }
}

/// The session's agent has been switched off in Settings: turn it back on, or pick another.
private struct DisabledAgentBanner: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "power").foregroundStyle(Theme.textSecondary)
            Text("\(agent.displayName) is turned off. Turn it on, or pick another agent below.")
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Turn On") { model.setEnabled(agent, true) }
                .controlSize(.small)
        }
        .font(Theme.Font.ui)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
