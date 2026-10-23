import Foundation

/// The project's setup script, run in a worktree it just made: a fresh checkout has no
/// `.env`, no installed dependencies, nothing git ignores.
public enum WorktreeSetup {
    public struct Result: Equatable, Sendable {
        public var status: Int32
        /// The end of what the script printed (stdout and stderr together).
        public var output: String
        public var seconds: Double
        public var timedOut = false

        public var succeeded: Bool { status == 0 && !timedOut }
    }

    /// Set for the script: where the main folder and the new worktree are.
    public static let mainFolderVariable = "MOUNTAGENT_MAIN_FOLDER"
    public static let worktreeVariable = "MOUNTAGENT_WORKTREE"

    /// Runs `script` with the login shell in `worktree`. Blocks; call it off the main thread.
    public static func run(_ script: String, in worktree: URL, mainFolder: URL, timeout: TimeInterval = 600) -> Result {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", script]
        process.currentDirectoryURL = worktree
        var environment = ExecutableLocator.environment
        environment[mainFolderVariable] = mainFolder.path
        environment[worktreeVariable] = worktree.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let output = OutputTail()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { output.append(data) }
        }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription, seconds: 0)
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            finished.wait()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { output.append(rest) }
        return Result(status: process.terminationStatus, output: output.text, seconds: Date().timeIntervalSince(started), timedOut: timedOut)
    }

    /// The last 8 KB, so an installer's progress bars can't fill memory.
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.withLock {
                data.append(more)
                if data.count > 16_384 { data = data.suffix(8_192) }
            }
        }

        var text: String {
            lock.withLock { String(decoding: data.suffix(8_192), as: UTF8.self) }
        }
    }
}
