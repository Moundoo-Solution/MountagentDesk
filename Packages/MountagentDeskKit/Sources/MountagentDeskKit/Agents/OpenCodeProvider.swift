import Foundation

/// Drives OpenCode headless: `opencode run --format json`, with the message on stdin (its
/// own argument joining would re-quote a message passed as arguments). Models are
/// `provider/model`, from whichever providers `opencode auth login` set up.
///
/// Access maps onto its agents and permissions: the read-only `plan` agent; the default
/// `build` agent, whose permission asks a headless run turns down; and `--auto`.
public struct OpenCodeProvider: AgentProvider {
    public let kind = AgentKind.opencode

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        var args = ["run", "--format", "json"]
        switch request.access {
        case .readOnly: args += ["--agent", "plan"]
        case .editFiles: break
        case .fullAccess: args.append("--auto")
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if let resume = request.resumeSessionID {
            args += ["--session", resume]
        }
        return AgentInvocation(arguments: args, stdin: request.promptWithContext(listingImages: true))
    }

    public func makeParser() -> any AgentStreamParser { OpenCodeStreamParser() }

    /// `opencode models`: one `provider/model` per line.
    public static func parseModels(_ output: String) -> [AgentModel] {
        let ids = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("/") && !$0.contains(" ") }
        return [AgentModel(id: nil, name: "Default")] + ids.map { AgentModel(id: $0, name: $0) }
    }
}

/// `opencode run --format json` lines: `step_start`, `text` (a finished text part),
/// `reasoning`, `tool_use` (a finished tool call), `step_finish` (tokens and cost) and
/// `error`, each with the `sessionID`. There is no closing line; the turn ends when the
/// process exits. Read from OpenCode's `run` command (v1.19).
public struct OpenCodeStreamParser: AgentStreamParser {
    private var sessionID: String?
    private var reply = ""
    private var error: String?
    private var input = 0
    private var output = 0
    private var cost = 0.0
    private var started: Double?
    private var ended: Double?

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        var events: [AgentEvent] = []
        if sessionID == nil, let id = object["sessionID"] as? String, !id.isEmpty {
            sessionID = id
            events.append(.sessionStarted(id: id, model: nil))
        }
        if let time = object["timestamp"] as? Double {
            started = started ?? time
            ended = time
        }
        let part = object["part"] as? JSONObject ?? [:]
        switch type {
        case "text":
            guard let text = part["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            reply = reply.isEmpty ? text : reply + "\n\n" + text
            events += [.textBlockStarted, .textDelta(text)]
        case "reasoning":
            if let text = part["text"] as? String, !text.isEmpty { events.append(.thinkingDelta(text)) }
        case "tool_use":
            let name = part["tool"] as? String ?? "tool"
            let id = part["callID"] as? String ?? part["id"] as? String ?? UUID().uuidString
            let state = part["state"] as? JSONObject ?? [:]
            let failed = state["status"] as? String == "error"
            events.append(.toolStarted(id: id, name: name, summary: ClaudeStreamParser.summary(name: name, input: Self.input(state["input"] as? JSONObject ?? [:]))))
            events.append(.toolFinished(id: id, output: (failed ? state["error"] : state["output"]) as? String ?? "", isError: failed))
        case "step_finish":
            let tokens = part["tokens"] as? JSONObject ?? [:]
            let cache = tokens["cache"] as? JSONObject ?? [:]
            input += (tokens["input"] as? Int ?? 0) + (cache["read"] as? Int ?? 0) + (cache["write"] as? Int ?? 0)
            output += (tokens["output"] as? Int ?? 0) + (tokens["reasoning"] as? Int ?? 0)
            cost += part["cost"] as? Double ?? 0
        case "error":
            let detail = object["error"] as? JSONObject ?? [:]
            let message = (detail["data"] as? JSONObject)?["message"] as? String ?? detail["message"] as? String ?? detail["name"] as? String
            error = [error, message].compactMap { $0 }.joined(separator: "\n")
        default:
            break
        }
        return events
    }

    public mutating func finish(exitStatus: Int32) -> [AgentEvent] {
        // Nothing parsed at all: let the runner report the exit and what was printed to stderr.
        guard sessionID != nil else { return [] }
        let failed = error != nil || exitStatus != 0
        return [.completed(TurnResult(
            isError: failed,
            text: failed ? (error ?? "OpenCode exited with code \(exitStatus).") : reply,
            durationMs: started.flatMap { start in ended.map { Int($0 - start) } },
            costUSD: cost > 0 ? cost : nil,
            inputTokens: input,
            outputTokens: output
        ))]
    }

    /// OpenCode's tools take `filePath`; the shared summary looks for `file_path`.
    private static func input(_ input: JSONObject) -> JSONObject {
        guard let path = input["filePath"] else { return input }
        var input = input
        input["file_path"] = path
        return input
    }
}
