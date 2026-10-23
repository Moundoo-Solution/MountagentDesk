import Foundation

public enum AgentRunError: LocalizedError {
    case executableNotFound(AgentKind)
    case launchFailed(String)
    case timedOut(AgentKind, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let kind):
            "\(kind.executableName) was not found. Install it, or set its path in Settings."
        case .launchFailed(let message):
            "Could not start the agent: \(message)"
        case .timedOut(let kind, let seconds):
            "\(kind.executableName) did not answer within \(seconds)s."
        }
    }
}

/// One running turn. Events arrive in stdout order; the stream finishes when the process exits.
public final class AgentRun: @unchecked Sendable {
    public let events: AsyncStream<AgentEvent>

    private let process: Process
    private let provider: any AgentProvider
    private let lock = NSLock()
    private var cancelled = false
    private var abandoned = false
    private var input: FileHandle?

    init(process: Process, provider: any AgentProvider, input: FileHandle?, events: AsyncStream<AgentEvent>) {
        self.process = process
        self.provider = provider
        self.input = input
        self.events = events
    }

    /// The failure reported when the user stops a turn; it isn't shown as an error.
    public static let stoppedMessage = "Stopped."

    public var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Stopped by Mountagent Desk because the CLI got stuck (e.g. waiting to sign in).
    var wasAbandoned: Bool {
        lock.withLock { abandoned }
    }

    /// Stops a CLI that can't go on; returns false if it was already stopped this way.
    func abandon() -> Bool {
        let first = lock.withLock {
            defer { abandoned = true }
            return !abandoned
        }
        guard first else { return false }
        closeInput()
        if process.isRunning { process.terminate() }
        return true
    }

    /// Answers a permission request the agent is waiting on. Returns false when the turn
    /// can no longer take answers.
    @discardableResult
    public func respond(_ reply: PermissionReply, to request: PermissionRequest) -> Bool {
        guard let line = provider.reply(reply, to: request) else { return false }
        return send(line)
    }

    /// Writes one line to the agent's stdin, if it is still open.
    @discardableResult
    func send(_ line: String) -> Bool {
        lock.withLock {
            guard let input else { return false }
            do {
                try input.write(contentsOf: Data((line + "\n").utf8))
                return true
            } catch {
                return false
            }
        }
    }

    func closeInput() {
        lock.withLock {
            try? input?.close()
            input = nil
        }
    }

    /// Asks the CLI to stop like Ctrl-C would, then kills it if it lingers.
    public func cancel() {
        lock.withLock { cancelled = true }
        closeInput()
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { process.terminate() }
        }
    }
}

public struct AgentRunner: Sendable {
    public var locator: ExecutableLocator

    public init(locator: ExecutableLocator = ExecutableLocator()) {
        self.locator = locator
    }

    public func start(_ request: AgentRunRequest, with provider: any AgentProvider) throws -> AgentRun {
        guard let executable = locator.locate(provider.kind) else {
            throw AgentRunError.executableNotFound(provider.kind)
        }
        let invocation = provider.invocation(for: request)

        let process = Process()
        process.executableURL = executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = ExecutableLocator.environment
            .merging(invocation.environment) { _, new in new }
            .merging(request.environment) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin: Pipe?
        if invocation.stdin != nil {
            stdin = Pipe()
            process.standardInput = stdin
        } else {
            stdin = nil
            process.standardInput = FileHandle.nullDevice
        }

        let (events, continuation) = AsyncStream<AgentEvent>.makeStream(bufferingPolicy: .unbounded)
        let interactive = invocation.keepsStdinOpen
        let run = AgentRun(
            process: process,
            provider: provider,
            input: interactive ? stdin?.fileHandleForWriting : nil,
            events: events
        )

        do {
            try process.run()
        } catch {
            throw AgentRunError.launchFailed(error.localizedDescription)
        }

        if let stdin, let text = invocation.stdin {
            if interactive {
                run.send(text)
            } else {
                let handle = stdin.fileHandleForWriting
                DispatchQueue.global().async {
                    try? handle.write(contentsOf: Data(text.utf8))
                    try? handle.close()
                }
            }
        }

        let errorOutput = OutputBuffer()
        let stderrDone = DispatchGroup()
        let signInPrompts = provider.signInPrompts
        let signInMessage = provider.signInMessage
        // A CLI asking to sign in would wait for an answer nobody can give; stop it instead.
        @Sendable func checkForSignIn(_ text: String) {
            guard signInPrompts.contains(where: text.contains), run.abandon() else { return }
            continuation.yield(.failure(signInMessage))
        }
        stderrDone.enter()
        DispatchQueue.global().async {
            let handle = stderr.fileHandleForReading
            var tail = ""
            while case let data = handle.availableData, !data.isEmpty {
                errorOutput.append(data)
                if !signInPrompts.isEmpty { tail = Self.scan(&tail, data, with: checkForSignIn) }
            }
            stderrDone.leave()
        }

        let parser = provider.makeParser()
        DispatchQueue.global().async {
            var parser = parser
            var lines = LineBuffer()
            var sawCompletion = false
            let handle = stdout.fileHandleForReading
            var tail = ""

            func emit(_ line: String) {
                for event in parser.parse(line: line) {
                    switch event {
                    case .reply(let answer):
                        run.send(answer)
                        continue
                    case .completed:
                        sawCompletion = true
                    default:
                        break
                    }
                    continuation.yield(event)
                    // With stdin held open the CLI waits for another message; closing it ends the turn.
                    if case .completed = event { run.closeInput() }
                }
            }

            // availableData returns as soon as anything arrives; read(upToCount:) would wait
            // for a full buffer, holding back streamed text and permission prompts.
            while case let data = handle.availableData, !data.isEmpty {
                // A sign-in question ends without a newline, so it never becomes a line.
                if !signInPrompts.isEmpty { tail = Self.scan(&tail, data, with: checkForSignIn) }
                lines.append(data).forEach(emit)
            }
            if let rest = lines.flush() { emit(rest) }

            run.closeInput()
            process.waitUntilExit()
            stderrDone.wait()

            if !sawCompletion, !run.wasCancelled, !run.wasAbandoned {
                for event in parser.finish(exitStatus: process.terminationStatus) {
                    if case .completed = event { sawCompletion = true }
                    continuation.yield(event)
                }
            }
            if run.wasCancelled {
                continuation.yield(.failure(AgentRun.stoppedMessage))
            } else if run.wasAbandoned {
                // Already explained.
            } else if !sawCompletion {
                let detail = errorOutput.tail
                let status = process.terminationStatus
                continuation.yield(.failure(detail.isEmpty ? "\(provider.kind.executableName) exited with code \(status)." : detail))
            }
            continuation.finish()
        }

        return run
    }

    /// Checks the previous chunk's end plus this chunk, so text split across two reads is
    /// still seen; returns the new end to carry over.
    private static func scan(_ tail: inout String, _ data: Data, with check: (String) -> Void) -> String {
        let text = tail + String(decoding: data, as: UTF8.self)
        check(text)
        return String(text.suffix(200))
    }

    /// Runs a short command to completion and returns its stdout (used for `--version`, model lists).
    public func capture(_ kind: AgentKind, arguments: [String], timeout: TimeInterval = 20) throws -> String {
        guard let executable = locator.locate(kind) else { throw AgentRunError.executableNotFound(kind) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ExecutableLocator.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()

        let collected = OutputBuffer(limit: 1_000_000)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            collected.append(output.fileHandleForReading.readDataToEndOfFile())
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw AgentRunError.timedOut(kind, seconds: Int(timeout))
        }
        process.waitUntilExit()
        return collected.text
    }
}

/// Splits a byte stream into UTF-8 lines without breaking multi-byte characters.
struct LineBuffer {
    private var pending = Data()
    /// How many bytes at the start of `pending` are known to hold no newline, so a long line
    /// arriving in many chunks is searched once, not from the start for every chunk.
    private var searched = 0

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var from = pending.startIndex + searched
        while let newline = pending[from...].firstIndex(of: 0x0A) {
            let line = pending[start..<newline]
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            start = newline + 1
            from = start
        }
        // Consumed lines go in one move, not one per line.
        if start > pending.startIndex { pending = Data(pending[start...]) }
        searched = pending.count
        return lines
    }

    mutating func flush() -> String? {
        defer {
            pending.removeAll()
            searched = 0
        }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// Thread-safe byte sink that keeps only the end of a long output.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int = 32_768) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data = data.suffix(limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }

    var tail: String {
        let lines = text.split(separator: "\n").suffix(12)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
