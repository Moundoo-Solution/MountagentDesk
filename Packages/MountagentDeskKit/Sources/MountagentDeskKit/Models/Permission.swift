import Foundation

/// A tool call the agent is waiting on (Claude asks over stdin and blocks until answered).
public struct PermissionRequest: Equatable, Sendable {
    public var id: String
    public var toolName: String
    public var summary: String
    /// Pretty-printed input, shown when the row is expanded.
    public var detail: String
    /// The rule "Always allow" would save, as the agent words it (e.g. `Bash(npm test)`).
    public var alwaysRule: String?
    /// Provider data needed to answer, kept opaque to the UI.
    public var payload: String

    public init(id: String, toolName: String, summary: String, detail: String, alwaysRule: String?, payload: String) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.alwaysRule = alwaysRule
        self.payload = payload
    }
}

public enum PermissionReply: Sendable {
    case allow
    case allowAlways
    case deny
}

/// A tool call the agent was refused without being able to ask (Cursor in headless mode).
/// It can be allowed and the turn retried.
public struct BlockedTool: Equatable, Sendable {
    public var callID: String
    public var toolName: String
    public var summary: String
    /// Rule for `.cursor/cli.json` that lets this call through, when one is known.
    public var rule: String?

    public init(callID: String, toolName: String, summary: String, rule: String?) {
        self.callID = callID
        self.toolName = toolName
        self.summary = summary
        self.rule = rule
    }
}

public enum PermissionState: String, Codable, Sendable {
    /// Claude is waiting for an answer.
    case pending
    case allowed
    case alwaysAllowed
    case denied
    /// The turn ended before anyone answered.
    case expired
    /// Cursor refused the call; it can be allowed and retried.
    case blocked
    case retriedOnce
    case retriedAlways
    case dismissed
}

/// Lets agents rename their session, so skills that "rename this chat" work in Mountagent Desk.
/// The agent is told the current title and ends its reply with a marker line, which is
/// removed from the transcript.
public enum SessionTitle {
    public static let marker = "Mountagent-Title:"
    /// Still accepted: skills written for the app's former name (AgentDesk) use it.
    static let markers = [marker, "AgentDesk-Title:"]

    public static func note(for title: String) -> String {
        """
        You are running inside Mountagent Desk, a desktop app for coding agents. This chat session \
        is titled "\(title)". Treat that title as the chat title wherever instructions or \
        skills refer to it. To rename this chat session, end your reply with a line of the \
        form "\(marker) <new title>"; Mountagent Desk renames the session and hides that line.
        """
    }

    /// Removes marker lines; returns the remaining text and the last title asked for.
    public static func extract(from text: String) -> (text: String, title: String?) {
        guard markers.contains(where: text.contains) else { return (text, nil) }
        var title: String?
        let kept = text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`*_"))
            guard let found = markers.first(where: trimmed.hasPrefix) else { return true }
            let value = trimmed.dropFirst(found.count).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*_"))
            if !value.isEmpty { title = String(value.prefix(200)) }
            return false
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .newlines), title)
    }
}
