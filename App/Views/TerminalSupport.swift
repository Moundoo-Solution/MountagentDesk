import MountagentDeskKit
import AppKit
import SwiftTerm
import SwiftUI

// Kept apart from the other views: SwiftTerm's own `Color` and `Button` types would
// shadow SwiftUI's in any file that imports it.

/// One login shell per project folder, kept alive while the app runs.
@MainActor
final class TerminalStore {
    static let shared = TerminalStore()
    private var views: [UUID: LocalProcessTerminalView] = [:]

    func view(for project: Project) -> LocalProcessTerminalView {
        if let view = views[project.id] { return view }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        TerminalShell.start(in: view, arguments: ["-l"], loginName: true, directory: project.path)
        views[project.id] = view
        return view
    }

    func restart(_ project: Project) {
        views.removeValue(forKey: project.id)?.terminate()
    }

    func terminateAll() {
        views.values.forEach { $0.terminate() }
        views.removeAll()
    }
}

struct TerminalHost: NSViewRepresentable {
    let project: Project
    let dark: Bool
    let theme: TerminalTheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = TerminalStore.shared.view(for: project)
        style(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        style(view)
    }

    private func style(_ view: LocalProcessTerminalView) {
        TerminalShell.style(view, dark: dark, theme: theme)
    }
}

/// The user's login shell in a terminal view, with the agents' PATH and the theme's colors.
enum TerminalShell {
    @MainActor
    static func start(in view: LocalProcessTerminalView, arguments: [String], loginName: Bool, directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var environment = ExecutableLocator.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // Colors in macOS's ls and other BSD tools.
        environment["CLICOLOR"] = "1"
        let name = (shell as NSString).lastPathComponent
        if name == "zsh", let zdotdir = zshDirectory {
            environment.merge(ShellPrompt.environment(zdotdir: zdotdir, current: environment)) { _, new in new }
        }
        view.startProcess(
            executable: shell,
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            // A leading dash makes it a login shell, as Terminal.app starts it.
            execName: loginName ? "-" + name : name,
            currentDirectory: directory
        )
    }

    /// Startup files that load the user's own and add a colored prompt (see `ShellPrompt`).
    @MainActor private static let zshDirectory = try? ShellPrompt.install(in: ProjectStore.defaultRoot())

    /// The scheme each view has, so the palette is only installed when it changes.
    @MainActor private static var installed: [ObjectIdentifier: TerminalTheme.Scheme] = [:]

    @MainActor
    static func style(_ view: LocalProcessTerminalView, dark: Bool, theme: TerminalTheme = .current) {
        let scheme = theme.scheme(dark: dark)
        guard installed[ObjectIdentifier(view)] != scheme else { return }
        installed[ObjectIdentifier(view)] = scheme
        view.nativeBackgroundColor = NSColor(hex: scheme.background)
        view.nativeForegroundColor = NSColor(hex: scheme.foreground)
        view.caretColor = NSColor(hex: scheme.cursor)
        view.installColors(scheme.ansi.map { hex in
            SwiftTerm.Color(red8: UInt16(hex >> 16 & 0xFF), green8: UInt16(hex >> 8 & 0xFF), blue8: UInt16(hex & 0xFF))
        })
    }
}


/// Lets the setup sheet type into its terminal (a pasted sign-in code).
@MainActor
final class TerminalInput {
    fileprivate weak var view: LocalProcessTerminalView?

    func send(_ text: String) {
        view?.send(data: ArraySlice(Array(text.utf8)))
    }
}

/// A terminal that hands what the program prints to `onOutput`, a few times a second.
/// SwiftTerm feeds output straight into its screen, so its host log (one file per chunk,
/// in a private temporary folder) is read back instead.
final class WatchedTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    private var timer: Timer?
    private var logDirectory: URL?
    private var nextChunk = 0
    private var output = ""

    func startWatching() {
        guard timer == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskSetup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logDirectory = directory
        setHostLogging(directory: directory.path)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLog() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        setHostLogging(directory: nil)
        if let logDirectory { try? FileManager.default.removeItem(at: logDirectory) }
        logDirectory = nil
    }

    private func readLog() {
        guard let logDirectory else { return }
        var grew = false
        while let data = try? Data(contentsOf: logDirectory.appendingPathComponent("log-\(nextChunk)")) {
            output += String(decoding: data, as: UTF8.self)
            nextChunk += 1
            grew = true
        }
        guard grew else { return }
        if output.count > 64_000 { output = String(output.suffix(32_000)) }
        onOutput?(output)
    }
}

/// Runs one setup command (install, sign in, update) in a real terminal, so prompts,
/// colors and the browser sign-in flow behave as in Terminal.app.
struct SetupTerminal: NSViewRepresentable {
    let command: String
    let dark: Bool
    var input: TerminalInput?
    var onOutput: ((String) -> Void)?
    let finished: (Int32?) -> Void

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var finished: (Int32?) -> Void

        init(finished: @escaping (Int32?) -> Void) {
            self.finished = finished
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let finished = finished
            DispatchQueue.main.async { finished(exitCode) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = WatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.onOutput = onOutput
        if onOutput != nil { view.startWatching() }
        input?.view = view
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = context.coordinator
        TerminalShell.style(view, dark: dark)
        TerminalShell.start(in: view, arguments: ["-l", "-c", command], loginName: false, directory: NSHomeDirectory())
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.finished = finished
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        (view as? WatchedTerminalView)?.stopWatching()
        view.terminate()
    }
}

// MARK: - Server terminals

/// SSH sessions opened from the Servers panel, kept while the app runs so switching panels
/// or sessions doesn't drop them. Each tab belongs to one project.
@MainActor
@Observable
final class ServerTerminals {
    static let shared = ServerTerminals()

    struct Tab: Identifiable, Equatable {
        let id = UUID()
        let serverID: UUID
        let projectID: UUID
        var connected = true
        /// Bumped on reconnect, so the panel swaps in the new terminal view.
        var generation = 0
    }

    private(set) var tabs: [Tab] = []
    /// The tab shown in each project's panel.
    var selected: [UUID: UUID] = [:]
    /// Called with (server id, command) whenever the user runs a command in a tab.
    @ObservationIgnored var onCommand: ((UUID, String) -> Void)?
    @ObservationIgnored private var views: [UUID: LocalProcessTerminalView] = [:]
    @ObservationIgnored private var watchers: [UUID: Watcher] = [:]

    func tabs(of projectID: UUID) -> [Tab] {
        tabs.filter { $0.projectID == projectID }
    }

    func open(_ login: SSHLogin, in projectID: UUID) {
        let tab = Tab(serverID: login.server.id, projectID: projectID)
        tabs.append(tab)
        start(login, in: tab.id)
        selected[projectID] = tab.id
    }

    func reconnect(_ tabID: UUID, to login: SSHLogin) {
        views.removeValue(forKey: tabID)?.terminate()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].connected = true
        tabs[index].generation += 1
        start(login, in: tabID)
    }

    func close(_ tabID: UUID) {
        views.removeValue(forKey: tabID)?.terminate()
        watchers[tabID] = nil
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        tabs.removeAll { $0.id == tabID }
        if selected[tab.projectID] == tabID { selected[tab.projectID] = tabs(of: tab.projectID).last?.id }
    }

    func terminateAll() {
        views.values.forEach { $0.terminate() }
        views.removeAll()
    }

    func view(for tabID: UUID) -> LocalProcessTerminalView? {
        views[tabID]
    }

    /// Types `text` at the prompt without pressing Return.
    func type(_ text: String, in tabID: UUID) {
        guard let view = views[tabID] else { return }
        view.send(data: ArraySlice(Array(text.utf8)))
        view.window?.makeFirstResponder(view)
    }

    func selection(in tabID: UUID) -> String? {
        views[tabID]?.getSelection().flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The last `count` non-blank lines on screen and in the scrollback.
    func recentOutput(in tabID: UUID, lines count: Int) -> String {
        guard let view = views[tabID] else { return "" }
        var lines = String(decoding: view.getBufferAsData(), as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }

    private func start(_ login: SSHLogin, in tabID: UUID) {
        let view = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let serverID = login.server.id
        view.onCommand = { [weak self] command in self?.onCommand?(serverID, command) }
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let watcher = Watcher { [weak self] _ in self?.disconnected(tabID) }
        watchers[tabID] = watcher
        view.processDelegate = watcher
        var environment = ExecutableLocator.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["CLICOLOR"] = "1"
        environment.merge(login.askpassEnvironment(askpass: ServerHelper.askpassExecutable)) { _, new in new }
        view.startProcess(
            executable: "/usr/bin/ssh",
            args: login.interactiveArguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: NSHomeDirectory()
        )
        views[tabID] = view
    }

    private func disconnected(_ tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].connected = false
    }

    final class Watcher: NSObject, LocalProcessTerminalViewDelegate {
        let ended: @MainActor (Int32?) -> Void

        init(ended: @escaping @MainActor (Int32?) -> Void) {
            self.ended = ended
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let ended = ended
            DispatchQueue.main.async { ended(exitCode) }
        }
    }
}

/// A terminal that reports the command on screen each time the user presses Return, for
/// the server's command history.
final class RecordingTerminalView: LocalProcessTerminalView {
    var onCommand: ((String) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // A typed Return (a paste of several lines is left alone).
        if data.count <= 2, data.contains(13), let onCommand {
            let tail = getBufferAsData().suffix(16_384)
            let screen = String(decoding: tail, as: UTF8.self)
            if let command = ServerCommandHistory.commandLine(fromScreen: screen, columns: terminalDimensions.cols) {
                onCommand(command)
            }
        }
        super.send(source: source, data: data)
    }
}

/// One server tab's terminal.
struct ServerTerminalHost: NSViewRepresentable {
    let tabID: UUID
    let dark: Bool
    let theme: TerminalTheme

    func makeNSView(context: Context) -> NSView {
        guard let view = ServerTerminals.shared.view(for: tabID) else { return NSView() }
        TerminalShell.style(view, dark: dark, theme: theme)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let view = view as? LocalProcessTerminalView { TerminalShell.style(view, dark: dark, theme: theme) }
    }
}

// MARK: - Terminal sessions

/// The programs terminal sessions run, kept while the app runs so switching sessions or
/// panes doesn't stop them. Started again when a session is first shown after a launch.
@MainActor
@Observable
final class SessionTerminals {
    static let shared = SessionTerminals()

    /// Sessions whose program has ended, with its exit code when there was one.
    private(set) var ended: [UUID: Int32?] = [:]
    @ObservationIgnored private var views: [UUID: LocalProcessTerminalView] = [:]
    @ObservationIgnored private var watchers: [UUID: ServerTerminals.Watcher] = [:]

    /// The session's terminal; `started` runs when its program is started anew.
    func view(for sessionID: UUID, command: String, directory: String, started: () -> Void = {}) -> LocalProcessTerminalView {
        if let view = views[sessionID] { return view }
        defer { started() }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let watcher = ServerTerminals.Watcher { [weak self, weak view] code in
            guard let self, let view, self.views[sessionID] === view else { return }
            self.ended[sessionID] = .some(code)
        }
        view.processDelegate = watcher
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interactive too (`-i`), so the program sees the aliases and keys set in .zshrc.
        let arguments = trimmed.isEmpty ? ["-l"] : ["-l", "-i", "-c", trimmed]
        TerminalShell.start(in: view, arguments: arguments, loginName: trimmed.isEmpty, directory: directory)
        views[sessionID] = view
        watchers[sessionID] = watcher
        ended[sessionID] = nil
        return view
    }

    func isRunning(_ sessionID: UUID) -> Bool {
        views[sessionID] != nil && ended[sessionID] == nil
    }

    /// Ends the program; the next `view(for:)` starts it again.
    func stop(_ sessionID: UUID) {
        views.removeValue(forKey: sessionID)?.terminate()
        watchers[sessionID] = nil
        ended[sessionID] = nil
    }

    func terminateAll() {
        views.values.forEach { $0.terminate() }
        views.removeAll()
        watchers.removeAll()
    }
}

/// A terminal session's program.
struct SessionTerminalHost: NSViewRepresentable {
    let sessionID: UUID
    let command: String
    let directory: String
    let dark: Bool
    let theme: TerminalTheme
    var started: () -> Void = {}

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = SessionTerminals.shared.view(for: sessionID, command: command, directory: directory, started: started)
        TerminalShell.style(view, dark: dark, theme: theme)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        TerminalShell.style(view, dark: dark, theme: theme)
    }
}
