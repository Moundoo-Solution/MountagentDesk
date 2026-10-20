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
        TerminalShell.style(view, dark: dark)
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
        let name = (shell as NSString).lastPathComponent
        view.startProcess(
            executable: shell,
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            // A leading dash makes it a login shell, as Terminal.app starts it.
            execName: loginName ? "-" + name : name,
            currentDirectory: directory
        )
    }

    @MainActor
    static func style(_ view: LocalProcessTerminalView, dark: Bool) {
        let ink = NSColor(hex: dark ? Theme.Hex.inkDark : Theme.Hex.inkLight)
        view.nativeBackgroundColor = NSColor(hex: dark ? Theme.Hex.sidebarDark : Theme.Hex.sidebarLight)
        view.nativeForegroundColor = ink.withAlphaComponent(0.92)
        view.caretColor = ink
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
