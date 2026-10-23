import Foundation

/// Drives Google's Gemini CLI headless: `gemini --prompt=… --output-format stream-json`.
/// It still serves Gemini API keys, Vertex AI and Workspace accounts; personal Google
/// accounts moved to Antigravity.
///
/// Access maps onto its approval modes: `plan` (read only), `auto_edit` (edits run, other
/// tools are refused headless) and `yolo`.
public struct GeminiProvider: AgentProvider {
    public let kind = AgentKind.gemini
    public let signInPrompts = ["Please visit the following URL to authorize", "Enter the authorization code"]

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        // `--skip-trust`: headless runs in an untrusted folder fall back to asking, which nobody can answer.
        var args = ["--output-format", "stream-json", "--skip-trust"]
        switch request.access {
        case .readOnly: args += ["--approval-mode", "plan"]
        case .editFiles: args += ["--approval-mode", "auto_edit"]
        case .fullAccess: args += ["--approval-mode", "yolo"]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        for directory in request.additionalDirectories {
            args += ["--include-directories", directory.path]
        }
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]
        }
        // Joined to the option, so a prompt starting with a dash stays the prompt.
        args.append("--prompt=" + request.promptWithContext(listingImages: true))
        return AgentInvocation(arguments: args, stdin: nil)
    }

    public func makeParser() -> any AgentStreamParser { GeminiStreamParser() }
}

/// Gemini CLI's stream-json lines, keyed by `type`: `init`, `message` (the reply in
/// deltas), `tool_use` / `tool_result`, `error` and the closing `result`. Read from the
/// CLI's own formatter (`JsonStreamEventType`).
public struct GeminiStreamParser: AgentStreamParser {
    private var inText = false
    private var reply = ""
    private var lastError: String?

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "init":
            guard let id = object["session_id"] as? String, !id.isEmpty else { return [] }
            return [.sessionStarted(id: id, model: object["model"] as? String)]
        case "message":
            guard object["role"] as? String == "assistant", let text = object["content"] as? String, !text.isEmpty else { return [] }
            var events: [AgentEvent] = []
            if !inText {
                events.append(.textBlockStarted)
                inText = true
            }
            reply += text
            events.append(.textDelta(text))
            return events
        case "tool_use":
            inText = false
            let name = object["tool_name"] as? String ?? "tool"
            let id = object["tool_id"] as? String ?? UUID().uuidString
            return [.toolStarted(id: id, name: name, summary: ClaudeStreamParser.summary(name: name, input: object["parameters"] as? JSONObject ?? [:]))]
        case "tool_result":
            let failed = object["status"] as? String == "error"
            let error = (object["error"] as? JSONObject)?["message"] as? String
            let output = object["output"] as? String ?? ""
            return [.toolFinished(id: object["tool_id"] as? String ?? "", output: failed && output.isEmpty ? (error ?? "") : output, isError: failed)]
        case "error":
            // Warnings (a retried request, a loop it broke out of) don't end the turn.
            if object["severity"] as? String == "error" { lastError = object["message"] as? String }
            return []
        case "result":
            let stats = object["stats"] as? JSONObject ?? [:]
            let failed = object["status"] as? String == "error"
            let error = ((object["error"] as? JSONObject)?["message"] as? String).map(Self.readable) ?? lastError
            return [.completed(TurnResult(
                isError: failed,
                text: failed ? (error ?? "Gemini CLI stopped with an error.") : reply,
                durationMs: stats["duration_ms"] as? Int,
                inputTokens: stats["input_tokens"] as? Int,
                outputTokens: stats["output_tokens"] as? Int
            ))]
        default:
            return []
        }
    }

    /// API errors arrive as JSON inside JSON inside text (`[API Error: {"error":{"message":
    /// "{\n \"error\": {… \"message\": \"API key not valid…`); the innermost message is the
    /// readable part.
    static func readable(_ message: String) -> String {
        let pattern = #"message\\*"\s*:\s*\\*"([^"\\]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let last = regex.matches(in: message, range: NSRange(message.startIndex..., in: message)).last,
              let range = Range(last.range(at: 1), in: message)
        else { return message }
        return String(message[range])
    }
}
