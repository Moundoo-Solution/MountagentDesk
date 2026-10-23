import Foundation

/// The coding agents Mountagent Desk can drive. Each one is a CLI installed on the machine.
public enum AgentKind: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case claude
    case cursor
    case codex
    /// Google's Antigravity CLI (`agy`), which replaced Gemini CLI for personal Google accounts.
    case antigravity
    /// GitHub Copilot CLI (`copilot`), signed in with a GitHub account that has Copilot.
    case copilot

    public var id: String { rawValue }

    /// An agent as saved by any version. Gemini CLI, which earlier versions drove, is read as
    /// Antigravity, its successor; an unknown name is nil.
    public init?(stored name: String) {
        if let kind = AgentKind(rawValue: name) {
            self = kind
        } else if name == "gemini" {
            self = .antigravity
        } else {
            return nil
        }
    }

    /// Unknown names decode as Claude rather than failing the whole project or session.
    public init(from decoder: any Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(stored: name) ?? .claude
    }

    /// Dictionary keys: an unknown agent's entry is dropped (see `ChatSession`).
    public init?(codingKey: some CodingKey) {
        self.init(stored: codingKey.stringValue)
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub Copilot"
        }
    }

    /// Turned on in a fresh install; the others wait until switched on in Settings → Agents.
    public var enabledByDefault: Bool {
        self == .claude || self == .cursor
    }

    /// Who makes it, for Settings.
    public var vendor: String {
        switch self {
        case .claude: "Anthropic"
        case .cursor: "Anysphere"
        case .codex: "OpenAI"
        case .antigravity: "Google"
        case .copilot: "GitHub"
        }
    }

    /// Executable name looked up on the PATH when no override is configured.
    public var executableName: String {
        switch self {
        case .claude: "claude"
        case .cursor: "cursor-agent"
        case .codex: "codex"
        case .antigravity: "agy"
        case .copilot: "copilot"
        }
    }

    /// Models offered before (or instead of) asking the CLI. `nil` id means the CLI default.
    public var builtInModels: [AgentModel] {
        switch self {
        case .claude:
            [
                AgentModel(id: nil, name: "Default"),
                AgentModel(id: "fable", name: "Fable"),
                AgentModel(id: "opus", name: "Opus"),
                AgentModel(id: "sonnet", name: "Sonnet"),
                AgentModel(id: "haiku", name: "Haiku"),
            ]
        case .cursor:
            [AgentModel(id: nil, name: "Auto")]
        case .codex:
            // The real list comes from `codex debug models`.
            [AgentModel(id: nil, name: "Default")]
        case .antigravity:
            // The real list comes from `agy models` once signed in.
            [AgentModel(id: nil, name: "Default")]
        case .copilot:
            // The real list comes from `copilot help config`.
            [AgentModel(id: nil, name: "Auto")]
        }
    }
}

public struct AgentModel: Hashable, Codable, Identifiable, Sendable {
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

/// How much the agent may do without asking. With `editFiles` the agent edits freely, and
/// what happens before commands and MCP tools depends on the CLI: Claude asks in the chat;
/// Cursor (which cannot wait when headless) reports the blocked call so it can be allowed
/// and retried; Codex runs commands in its workspace sandbox; Antigravity refuses them;
/// Copilot runs read-only commands and reports the others so they can be allowed and retried.
public enum AccessLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly
    case editFiles
    case fullAccess

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readOnly: "Read only (plan)"
        case .editFiles: "Ask for commands"
        case .fullAccess: "Full access"
        }
    }

    public var symbolName: String {
        switch self {
        case .readOnly: "eye"
        case .editFiles: "hand.raised"
        case .fullAccess: "bolt.fill"
        }
    }
}
