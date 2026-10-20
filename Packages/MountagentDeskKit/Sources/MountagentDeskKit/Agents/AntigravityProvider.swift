import Foundation

/// Drives Google's Antigravity CLI headless: `agy -p --output-format stream-json`.
///
/// Access maps onto its modes: `plan` (read only), `accept-edits` (edits run, other tools
/// are refused headless), and `--dangerously-skip-permissions`.
public struct AntigravityProvider: AgentProvider {
    public let kind = AgentKind.antigravity
    /// An expired sign-in makes it print a link and wait for a code.
    public let signInPrompts = ["paste the authorization code", "Waiting for authentication", "You are not logged into Antigravity"]

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        var args = ["-p", "--output-format", "stream-json", "--print-timeout", "0s"]
        switch request.access {
        case .readOnly: args += ["--mode", "plan"]
        case .editFiles: args += ["--mode", "accept-edits"]
        case .fullAccess: args.append("--dangerously-skip-permissions")
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = request.effort, !effort.isEmpty {
            args += ["--effort", effort]
        }
        for directory in request.additionalDirectories {
            args += ["--add-dir", directory.path]
        }
        if let resume = request.resumeSessionID {
            args += ["--conversation", resume]
        }
        // `--` ends the options, so a prompt starting with a dash stays the prompt.
        args += ["--", request.promptWithContext(listingImages: true)]
        return AgentInvocation(arguments: args, stdin: nil)
    }

    public func makeParser() -> any AgentStreamParser { AntigravityStreamParser() }
}

/// Antigravity's stream-json lines, keyed by `event`. This reads the closing `result`
/// (the reply, conversation id, usage), recorded from a real run; the streaming events
/// before it are not shown yet, so a turn's reply appears when it finishes.
public struct AntigravityStreamParser: AgentStreamParser {
    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let event = object["event"] as? String else { return [] }
        switch event {
        case "result":
            let result = object["result"] as? JSONObject ?? [:]
            let usage = result["usage"] as? JSONObject ?? [:]
            var events: [AgentEvent] = []
            if let id = result["conversation_id"] as? String, !id.isEmpty {
                events.append(.sessionStarted(id: id, model: nil))
            }
            let failed = (result["status"] as? String)?.uppercased() == "ERROR"
            let response = result["response"] as? String
            if !failed, let response, !response.isEmpty {
                events += [.textBlockStarted, .textDelta(response)]
            }
            events.append(.completed(TurnResult(
                isError: failed,
                text: failed ? (result["error"] as? String) : response,
                durationMs: (result["duration_seconds"] as? Double).map { Int($0 * 1000) },
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: (usage["output_tokens"] as? Int).map { $0 + (usage["thinking_tokens"] as? Int ?? 0) }
            )))
            return events
        default:
            return []
        }
    }
}
