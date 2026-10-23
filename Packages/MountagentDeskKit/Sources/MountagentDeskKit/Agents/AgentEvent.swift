import Foundation

/// What every agent's stream is normalised into. The transcript reducer and the UI only
/// ever see these, never a CLI's own JSON.
public enum AgentEvent: Equatable, Sendable {
    /// The CLI reported its own session id (used later for `--resume`).
    case sessionStarted(id: String, model: String?)
    /// A new text block begins; the next delta must not join the previous block.
    case textBlockStarted
    /// A piece of assistant text to append to the open block.
    case textDelta(String)
    /// The full text of the open block, replacing whatever was streamed so far.
    case textSnapshot(String)
    case thinkingDelta(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolFinished(id: String, output: String, isError: Bool)
    /// The agent is paused until the request is answered through `AgentRun.respond`.
    case permissionRequest(PermissionRequest)
    /// The agent was refused a tool call it could not ask about.
    case toolBlocked(BlockedTool)
    /// A line the runner writes back to the agent's stdin without involving the UI.
    case reply(String)
    /// The account's plan limits, as of this turn.
    case rateLimit(RateLimitInfo)
    case completed(TurnResult)
    case failure(String)
}

public struct TurnResult: Equatable, Codable, Sendable {
    public var isError: Bool
    public var text: String?
    public var durationMs: Int?
    public var costUSD: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(isError: Bool, text: String? = nil, durationMs: Int? = nil, costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.isError = isError
        self.text = text
        self.durationMs = durationMs
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Turns one line of a CLI's stdout into zero or more events. Parsers keep per-run state,
/// so a fresh one is made for every run.
public protocol AgentStreamParser: Sendable {
    mutating func parse(line: String) -> [AgentEvent]
}

/// Everything needed to start one turn.
public struct AgentRunRequest: Sendable {
    public var prompt: String
    public var workingDirectory: URL
    /// Extra folders the agent may read and edit (`--add-dir`).
    public var additionalDirectories: [URL]
    /// Load CLAUDE.md / AGENTS.md from the additional folders too.
    public var loadsAdditionalRules: Bool
    public var model: String?
    /// Reasoning effort (`low` … `max`) for CLIs that take it as an option.
    public var effort: String?
    public var access: AccessLevel
    public var resumeSessionID: String?
    /// Mountagent Desk's title for the session, shown to the agent so it can refer to and rename it.
    public var sessionTitle: String?
    /// Images to show the agent with this message (PNG / JPEG / GIF / WebP files).
    public var images: [URL] = []
    /// The project has servers; agents must not reach them with their own ssh.
    public var linksServers = false
    /// Some of them are readable through `mountagent-server`.
    public var readsServers = false
    /// Added to the agent's environment (the server helper on PATH, the project id).
    public var environment: [String: String] = [:]

    public init(
        prompt: String,
        workingDirectory: URL,
        additionalDirectories: [URL] = [],
        loadsAdditionalRules: Bool = false,
        model: String?,
        effort: String? = nil,
        access: AccessLevel,
        resumeSessionID: String?,
        sessionTitle: String? = nil
    ) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.loadsAdditionalRules = loadsAdditionalRules
        self.model = model
        self.effort = effort
        self.access = access
        self.resumeSessionID = resumeSessionID
        self.sessionTitle = sessionTitle
    }
}

extension AgentRunRequest {
    /// The message for CLIs without a system-prompt option: the extra folders' rules on a
    /// session's first message, the images listed by path for CLIs that can't take image
    /// input but can open files, and Mountagent Desk's note about the session title.
    func promptWithContext(listingImages: Bool) -> String {
        var prompt = prompt
        if loadsAdditionalRules, resumeSessionID == nil, let rules = Self.additionalRules(in: additionalDirectories) {
            prompt = rules + "\n\n" + prompt
        }
        if listingImages, !images.isEmpty {
            prompt += "\n\nAttached images (open them with your file reading tool before answering):\n"
                + images.map { "- \($0.path)" }.joined(separator: "\n")
        }
        if let sessionTitle {
            prompt = "<mountagent>\(SessionTitle.note(for: sessionTitle))</mountagent>\n\n" + prompt
        }
        return prompt
    }

    /// The extra folders' AGENTS.md (or CLAUDE.md). Only Claude loads rules from `--add-dir`
    /// folders, so the other CLIs get them with the first message of a session.
    static func additionalRules(in directories: [URL], limit: Int = 20_000) -> String? {
        let sections = directories.compactMap { directory -> String? in
            for name in ["AGENTS.md", "CLAUDE.md"] {
                let file = directory.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                return "<folder_rules path=\"\(directory.path)\" file=\"\(name)\">\n\(text.truncated(to: limit))\n</folder_rules>"
            }
            return nil
        }
        guard !sections.isEmpty else { return nil }
        return "Rules for the additional project folders. Follow them when working in those folders.\n\n"
            + sections.joined(separator: "\n\n")
    }

}

/// The command line for one turn, before the executable is resolved.
public struct AgentInvocation: Equatable, Sendable {
    public var arguments: [String]
    /// Written to the process's stdin, which is then closed (or, with `keepsStdinOpen`,
    /// kept open for replies until the turn completes). `nil` connects /dev/null.
    public var stdin: String?
    public var keepsStdinOpen = false
    /// Added to the child process's environment.
    public var environment: [String: String] = [:]
}

public protocol AgentProvider: Sendable {
    var kind: AgentKind { get }
    /// Text a CLI prints (on either stream) when it wants to sign in interactively, which a
    /// headless turn can't do: the run is stopped and `signInMessage` shown instead of hanging.
    var signInPrompts: [String] { get }
    func invocation(for request: AgentRunRequest) -> AgentInvocation
    func makeParser() -> any AgentStreamParser
    /// The stdin line that answers a permission request.
    func reply(_ reply: PermissionReply, to request: PermissionRequest) -> String?
}

extension AgentProvider {
    public func reply(_ reply: PermissionReply, to request: PermissionRequest) -> String? { nil }
    public var signInPrompts: [String] { [] }

    public var signInMessage: String {
        "\(kind.displayName) needs you to sign in again. Open Settings → Agents → \(kind.displayName) → Sign In…, then resend."
    }
}

public enum AgentProviders {
    public static func provider(for kind: AgentKind) -> any AgentProvider {
        switch kind {
        case .claude: ClaudeProvider()
        case .cursor: CursorProvider()
        case .codex: CodexProvider()
        case .antigravity: AntigravityProvider()
        case .copilot: CopilotProvider()
        }
    }
}

// MARK: - JSON helpers shared by the parsers

typealias JSONObject = [String: Any]

enum JSONLine {
    static func object(_ line: String) -> JSONObject? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else { return nil }
        return value
    }

    static func encode(_ object: JSONObject) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Compact, key-sorted JSON for showing an arbitrary value in a tool row.
    static func compact(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return string
    }
}

extension String {
    func truncated(to limit: Int) -> String {
        count > limit ? String(prefix(limit)) + "…" : self
    }

    var firstLine: String {
        split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? self
    }
}
