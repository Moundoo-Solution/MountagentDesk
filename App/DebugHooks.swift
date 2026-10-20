#if DEBUG
import MountagentDeskKit
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Debug builds only, driven by environment variables so the app can be exercised from a
/// script without Screen Recording or Accessibility permission. Pair them with
/// `MOUNTAGENT_DATA_DIR` (read by every build) to work on a copy of the data.
///
/// Driving a session:
/// - `MOUNTAGENT_AUTOSEND="prompt"` sends a prompt to the selected session after launch.
/// - `MOUNTAGENT_AUTOANSWER=allow|always|deny|retry|retry-always` presses that button on
///   each permission row of the selected session as it appears.
/// - `MOUNTAGENT_PASTE_IMAGE=path` pastes an image into the composer (from a private
///   pasteboard); `MOUNTAGENT_SEND_IMAGE=path` sends it, with `MOUNTAGENT_SEND_TEXT`.
/// - `MOUNTAGENT_SELECT_REPLY` selects the last reply's text; `MOUNTAGENT_ACTIVATE` brings
///   the window forward with the composer focused.
///
/// Opening things to look at:
/// - `MOUNTAGENT_LAYOUT=single|columns|rows|grid` splits the chat area (filled with recent
///   sessions), `MOUNTAGENT_FOCUS_PANE=n` focuses a pane.
/// - `MOUNTAGENT_SHOW_SETTINGS=<pane>`, `MOUNTAGENT_SHOW_FOLDERS`, `MOUNTAGENT_SHOW_GIT`
///   (`editor` for the account editor), `MOUNTAGENT_SHOW_GIT_WINDOW=changes|history`,
///   `MOUNTAGENT_NEW_BRANCH=<repo>` open those windows and sheets.
/// - `MOUNTAGENT_SETUP_DEMO="command"` runs a command in the setup sheet
///   (`MOUNTAGENT_SETUP_DEMO_SIGNIN` with the sign-in bar).
///
/// Capturing:
/// - `MOUNTAGENT_WINDOW_SIZE=WxH` resizes the main window.
/// - `MOUNTAGENT_SNAPSHOT=/path/prefix` writes `<prefix>-window<n>.png` of each window and
///   `<prefix>-transcript.png` of the selected session after `MOUNTAGENT_SNAPSHOT_DELAY`
///   seconds (default 3).
///
/// Elsewhere: `MOUNTAGENT_SELECT_COMMITS` / `MOUNTAGENT_OPEN_SQUASH` (Git workspace) and
/// `MOUNTAGENT_OPEN_FILE` (Files panel), also debug-only.
enum DebugHooks {
    @MainActor private static var debugWindows: [NSWindow] = []

    @MainActor
    static func run(model: @escaping @MainActor () -> AppModel?) {
        let environment = ProcessInfo.processInfo.environment
        if let answer = environment["MOUNTAGENT_AUTOANSWER"] {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let model = model(), let session = model.selectedSession else { return }
                    for item in session.items where item.kind == .permission {
                        switch (item.permissionState, answer) {
                        case (.pending, "allow"): model.answer(.allow, item: item.id, in: session.id)
                        case (.pending, "always"): model.answer(.allowAlways, item: item.id, in: session.id)
                        case (.pending, "deny"): model.answer(.deny, item: item.id, in: session.id)
                        case (.blocked, "retry"): model.retryBlocked(item: item.id, in: session.id, always: false)
                        case (.blocked, "retry-always"): model.retryBlocked(item: item.id, in: session.id, always: true)
                        default: continue
                        }
                        return
                    }
                }
            }
        }
        if let prompt = environment["MOUNTAGENT_AUTOSEND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let model = model(), let id = model.selectedSessionID else { return }
                    model.send(prompt, attachments: [], in: id)
                }
            }
        }
        if let command = environment["MOUNTAGENT_SETUP_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    if environment["MOUNTAGENT_SETUP_DEMO_SIGNIN"] != nil {
                        model()?.setupTask = AppModel.SetupTask(kind: .antigravity, title: "Sign in to Antigravity", command: command,
                                                                hint: AgentSetup.loginHint(for: .antigravity), signIn: AgentSetup.signInFlow(for: .antigravity))
                    } else {
                        model()?.setupTask = AppModel.SetupTask(kind: .cursor, title: "Sign in to Cursor", command: command)
                    }
                }
            }
        }
        if let pane = environment["MOUNTAGENT_SHOW_SETTINGS"].flatMap(SettingsPane.init(rawValue:)) {
            // The Settings scene can't be opened from here; host the same view in a window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let model = model() else { return }
                    SettingsPane.show(pane)
                    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.title = "Settings"
                    window.contentView = NSHostingView(rootView: SettingsView().environment(model))
                    window.makeKeyAndOrderFront(nil)
                    debugWindows.append(window)
                }
            }
        }
        if environment["MOUNTAGENT_SHOW_FOLDERS"] != nil || environment["MOUNTAGENT_SHOW_GIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let model = model() else { return }
                    if environment["MOUNTAGENT_SHOW_FOLDERS"] != nil {
                        model.foldersProject = model.projects.first
                    } else {
                        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                        window.title = "Git"
                        if environment["MOUNTAGENT_SHOW_GIT"] == "editor", let account = model.gitAccounts.last {
                            window.setContentSize(NSSize(width: 560, height: 640))
                            window.contentView = NSHostingView(rootView: GitAccountEditor(account: account).environment(model))
                        } else {
                            SettingsPane.show(.git)
                            window.setContentSize(NSSize(width: 900, height: 640))
                            window.contentView = NSHostingView(rootView: SettingsView().environment(model))
                        }
                        window.makeKeyAndOrderFront(nil)
                        debugWindows.append(window)
                    }
                }
            }
        }
        if let size = environment["MOUNTAGENT_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                    window.setFrame(NSRect(x: 20, y: 20, width: size[0], height: size[1]), display: true)
                }
            }
        }
        if let path = environment["MOUNTAGENT_PASTE_IMAGE"] {
            // Pastes through the same path as ⌘V, from a private pasteboard (not the user's).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name("MountagentDeskDebugPaste"))
                    pasteboard.clearContents()
                    if let image = NSImage(contentsOfFile: path) { pasteboard.writeObjects([image]) }
                    ComposerPasteRouter.current?.onPaste?(ImageAttachments.read(pasteboard))
                    pasteboard.releaseGlobally()
                }
            }
        }
        if let path = environment["MOUNTAGENT_SEND_IMAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard let model = model(), let id = model.selectedSessionID,
                          let saved = ImageAttachments.importImage(at: URL(fileURLWithPath: path)) else { return }
                    model.send(environment["MOUNTAGENT_SEND_TEXT"] ?? "What is in this image?", attachments: [], images: [saved], in: id)
                }
            }
        }
        if let tab = environment["MOUNTAGENT_SHOW_GIT_WINDOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    guard let model = model(), let root = model.projects.first?.path else { return }
                    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1300, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = "Git"
                    window.contentView = NSHostingView(rootView: GitWindow(root: root, tab: tab == "history" ? .history : .changes).environment(model))
                    window.makeKeyAndOrderFront(nil)
                    debugWindows.append(window)
                }
            }
        }
        if let root = environment["MOUNTAGENT_NEW_BRANCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated {
                    let repo = GitRepoModel(root: root)
                    Task {
                        await repo.refresh()
                        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 440, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
                        window.contentView = NSHostingView(rootView: NewBranchSheet(repo: repo, naming: Naming(title: "New branch", message: "", start: "", choosesStart: true)))
                        window.makeKeyAndOrderFront(nil)
                        debugWindows.append(window)
                    }
                }
            }
        }
        if let layout = environment["MOUNTAGENT_LAYOUT"].flatMap(PaneGrid.Layout.init(rawValue:)) {
            // Split the chat area and fill the panes with recent sessions, for snapshots.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated {
                    guard let model = model() else { return }
                    model.setLayout(layout)
                    let recent = model.sessions.values.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
                    for (index, id) in recent.prefix(layout.paneCount).enumerated() { model.open(id, inPane: index) }
                    if let focus = environment["MOUNTAGENT_FOCUS_PANE"].flatMap(Int.init) { model.focusPane(focus) }
                }
            }
        }
        if environment["MOUNTAGENT_ACTIVATE"] != nil {
            // Brings the window forward and puts the caret in the composer, as after a click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate(ignoringOtherApps: true)
                guard let window = NSApp.windows.first(where: \.isVisible) else { return }
                window.makeKeyAndOrderFront(nil)
                @MainActor func editable(in view: NSView) -> NSTextView? {
                    if let text = view as? NSTextView, text.isEditable { return text }
                    return view.subviews.lazy.compactMap(editable).first
                }
                if let editor = window.contentView.flatMap(editable) { window.makeFirstResponder(editor) }
            }
        }
        if environment["MOUNTAGENT_SELECT_REPLY"] != nil {
            // Selects the first reply's text from its second paragraph to the end, to check
            // that a selection runs across paragraphs, lists and code.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                @MainActor func textViews(in view: NSView) -> [NSTextView] {
                    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
                }
                guard let content = NSApp.windows.first(where: \.isVisible)?.contentView,
                      let reply = textViews(in: content).first(where: { !$0.isEditable && $0.string.count > 40 })
                else { return }
                let start = (reply.string as NSString).range(of: "Hi ").location
                reply.window?.makeFirstResponder(reply)
                reply.setSelectedRange(NSRange(location: start == NSNotFound ? 0 : start, length: reply.string.utf16.count - (start == NSNotFound ? 0 : start)))
            }
        }
        if let prefix = environment["MOUNTAGENT_SNAPSHOT"] {
            let delay = Double(environment["MOUNTAGENT_SNAPSHOT_DELAY"] ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    captureWindows(prefix: prefix)
                    guard let model = model(), let session = model.selectedSession else { return }
                    renderTranscript(session, project: model.project(session.projectID), to: URL(fileURLWithPath: "\(prefix)-transcript.png"))
                }
            }
        }
    }

    /// Real pixels of the app's own windows, via the window server. Tries the legacy
    /// CGWindowList call first (allowed for a process's own windows), then ScreenCaptureKit.
    @MainActor
    private static func captureWindows(prefix: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let handle = dlopen(nil, RTLD_NOW)
        let symbol = dlsym(handle, "CGWindowListCreateImage")
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.windowNumber > 0 {
            let url = URL(fileURLWithPath: "\(prefix)-window\(index).png")
            if let symbol {
                let create = unsafeBitCast(symbol, to: CreateImage.self)
                // .null rect, .optionIncludingWindow (8), .boundsIgnoreFraming (1)
                if let image = create(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
                    write(image, to: url)
                    continue
                }
            }
            let number = window.windowNumber
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let target = content.windows.first(where: { $0.windowID == CGWindowID(number) }) else { return }
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(target.frame.width * 2)
                    configuration.height = Int(target.frame.height * 2)
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
                    write(image, to: url)
                } catch {
                    try? "capture failed: \(error)".write(to: url.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Off-screen render of a session's rows. Window captures miss list and scroll content,
    /// and ImageRenderer draws buttons and scroll views as placeholders.
    @MainActor
    private static func renderTranscript(_ session: ChatSession, project: Project?, to url: URL) {
        let content = VStack(alignment: .leading, spacing: 0) {
            TranscriptRows(items: session.items, isRunning: false)
        }
        .padding(24)
        .frame(width: Theme.columnWidth + 48)
        .background(Theme.background)
        .environment(\.project, project)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
#endif
