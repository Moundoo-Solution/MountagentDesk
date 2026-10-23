import Foundation

/// One line under a session in the sidebar: what its agent is doing, what it waits for,
/// or how its last turn ended.
public enum SessionActivity {
    public enum State: Equatable, Sendable {
        case working, waiting, failed, finished
    }

    public struct Line: Equatable, Sendable {
        public let state: State
        public let text: String
    }

    public static func line(for session: ChatSession, running: Bool) -> Line? {
        let items = session.items
        if let question = items.last(where: { $0.kind == .permission && $0.permissionState == .pending }) {
            return Line(state: .waiting, text: "Needs you: \(verb(question.toolName)) \(oneLine(question.text))")
        }
        if running {
            guard let last = items.last else { return Line(state: .working, text: "Starting…") }
            switch last.kind {
            case .tool where last.toolStatus == .running: return Line(state: .working, text: "\(doing(last.toolName)) \(oneLine(last.text))")
            case .thinking: return Line(state: .working, text: "Thinking…")
            case .assistant: return Line(state: .working, text: "Writing a reply…")
            case .user: return Line(state: .working, text: "Starting…")
            default: return Line(state: .working, text: "Working…")
            }
        }
        guard let last = items.last(where: { $0.kind == .assistant || ($0.kind == .notice && $0.isError) }) else { return nil }
        if last.kind == .notice { return Line(state: .failed, text: oneLine(last.text)) }
        let reply = oneLine(SessionTitle.extract(from: last.text).text)
        return reply.isEmpty ? nil : Line(state: .finished, text: reply)
    }

    /// The first line with words, without Markdown marks.
    static func oneLine(_ text: String) -> String {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.replacingOccurrences(of: #"^(#+|>|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    static func verb(_ tool: String?) -> String {
        switch tool?.lowercased() ?? "" {
        case "read", "readfile": "read"
        case "edit", "multiedit", "applypatch": "edit"
        case "write", "writefile": "write"
        case "bash", "shell", "terminal": "run"
        case "grep", "search", "glob", "ls": "search"
        case "webfetch", "fetch": "fetch"
        case "": "use a tool:"
        default: "use \(tool!):"
        }
    }

    static func doing(_ tool: String?) -> String {
        switch tool?.lowercased() ?? "" {
        case "read", "readfile": "Reading"
        case "edit", "multiedit", "applypatch": "Editing"
        case "write", "writefile": "Writing"
        case "bash", "shell", "terminal": "Running"
        case "grep", "search", "glob", "ls": "Searching"
        case "webfetch", "fetch": "Fetching"
        case "": "Using a tool:"
        default: "Using \(tool!):"
        }
    }
}
