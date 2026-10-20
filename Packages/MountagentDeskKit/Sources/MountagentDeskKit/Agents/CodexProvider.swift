import Foundation

/// Drives OpenAI's `codex exec --json` (and `codex exec resume` for later turns).
///
/// Codex can't stop to ask in exec mode, so access maps onto its sandbox: read-only,
/// workspace-write (commands run sandboxed, edits stay inside the project folders), or no
/// sandbox at all. The prompt goes in on stdin, so nothing in it is read as an option.
public struct CodexProvider: AgentProvider {
    public let kind = AgentKind.codex

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        var args = ["exec"]
        if request.resumeSessionID != nil { args.append("resume") }
        args += ["--json", "--skip-git-repo-check"]
        switch request.access {
        case .readOnly:
            args += ["-c", "sandbox_mode=\"read-only\""]
        case .editFiles:
            args += ["-c", "sandbox_mode=\"workspace-write\""]
            if !request.additionalDirectories.isEmpty {
                // `--add-dir` exists for new sessions only; the config key works for both.
                let roots = request.additionalDirectories.map { Self.tomlString($0.path) }.joined(separator: ", ")
                args += ["-c", "sandbox_workspace_write.writable_roots=[\(roots)]"]
            }
        case .fullAccess:
            args.append("--dangerously-bypass-approvals-and-sandbox")
        }
        if let model = request.model, !model.isEmpty {
            args += ["-m", model]
        }
        if let effort = request.effort, !effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\(Self.tomlString(effort))"]
        }
        for image in request.images {
            args += ["-i", image.path]
        }
        if let resume = request.resumeSessionID {
            args.append(resume)
        } else {
            args += ["-C", request.workingDirectory.path]
        }
        args.append("-")

        // Images go in with `-i`.
        return AgentInvocation(arguments: args, stdin: request.promptWithContext(listingImages: false))
    }

    public func makeParser() -> any AgentStreamParser { CodexStreamParser() }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One entry of `codex debug models`: the model, the efforts it takes, and its default.
    public struct Model: Hashable, Sendable {
        public var model: AgentModel
        public var efforts: [String]
        public var defaultEffort: String?
    }

    /// The models `codex debug models` lists for the picker, in Codex's own order.
    public static func parseModels(_ json: String) -> [Model] {
        guard let object = JSONLine.object(json), let models = object["models"] as? [JSONObject] else { return [] }
        return models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { entry in
                guard let slug = entry["slug"] as? String else { return nil }
                let efforts = (entry["supported_reasoning_levels"] as? [JSONObject] ?? []).compactMap { $0["effort"] as? String }
                return Model(model: AgentModel(id: slug, name: entry["display_name"] as? String ?? slug),
                             efforts: efforts,
                             defaultEffort: entry["default_reasoning_level"] as? String)
            }
    }
}

/// Codex's JSONL events. Messages arrive whole (no deltas); commands, edits and MCP calls
/// come as items that start and complete.
public struct CodexStreamParser: AgentStreamParser {
    private var lastMessage: String?
    private var started: Set<String> = []

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            guard let id = object["thread_id"] as? String else { return [] }
            return [.sessionStarted(id: id, model: nil)]

        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? JSONObject else { return [] }
            return self.item(item, completed: type == "item.completed")

        case "turn.completed":
            let usage = object["usage"] as? JSONObject ?? [:]
            return [.completed(TurnResult(
                isError: false,
                text: lastMessage,
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: (usage["output_tokens"] as? Int).map { $0 + (usage["reasoning_output_tokens"] as? Int ?? 0) }
            ))]

        case "turn.failed":
            let message = (object["error"] as? JSONObject)?["message"] as? String ?? "Codex stopped with an error."
            return [.completed(TurnResult(isError: true, text: message))]

        case "error":
            return [.failure(object["message"] as? String ?? "Codex reported an error.")]

        default:
            return []
        }
    }

    private mutating func item(_ item: JSONObject, completed: Bool) -> [AgentEvent] {
        let id = item["id"] as? String ?? UUID().uuidString
        let status = item["status"] as? String
        switch item["type"] as? String {
        case "agent_message":
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
            lastMessage = text
            return [.textBlockStarted, .textDelta(text)]

        case "reasoning":
            guard completed, let text = item["text"] as? String, !text.isEmpty else { return [] }
            return [.thinkingDelta(text)]

        case "command_execution":
            let command = Self.unwrapShell(item["command"] as? String ?? "")
            guard completed else { return start(id, "Shell", command) }
            let exit = item["exit_code"] as? Int
            return start(id, "Shell", command) + [.toolFinished(
                id: id,
                output: item["aggregated_output"] as? String ?? "",
                isError: status == "failed" || (exit ?? 0) != 0
            )]

        case "file_change":
            let changes = item["changes"] as? [JSONObject] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            let summary = paths.count == 1 ? paths[0] : "\(paths.count) files"
            guard completed else { return start(id, "Edit", summary) }
            let output = changes.map { "\($0["kind"] as? String ?? "update") \($0["path"] as? String ?? "")" }.joined(separator: "\n")
            return start(id, "Edit", summary) + [.toolFinished(id: id, output: output, isError: status == "failed")]

        case "mcp_tool_call":
            let summary = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: " · ")
            guard completed else { return start(id, "MCP", summary) }
            let error = (item["error"] as? JSONObject)?["message"] as? String
            let output = error ?? Self.mcpOutput(item["result"])
            return start(id, "MCP", summary) + [.toolFinished(id: id, output: output, isError: error != nil || status == "failed")]

        case "web_search":
            let query = item["query"] as? String ?? ""
            guard completed else { return start(id, "WebSearch", query) }
            return start(id, "WebSearch", query) + [.toolFinished(id: id, output: "", isError: false)]

        case "todo_list":
            let entries = item["items"] as? [JSONObject] ?? []
            let lines = entries.map { "\(($0["completed"] as? Bool) == true ? "✓" : "○") \($0["text"] as? String ?? "")" }
            let done = entries.filter { ($0["completed"] as? Bool) == true }.count
            return start(id, "TodoWrite", "\(done)/\(entries.count) done") + [.toolFinished(id: id, output: lines.joined(separator: "\n"), isError: false)]

        default:
            // `error` items are warnings (e.g. a deprecated setting in config.toml); a failed
            // turn arrives as `turn.failed`.
            return []
        }
    }

    /// Emits `toolStarted` once per item, however many updates it gets.
    private mutating func start(_ id: String, _ name: String, _ summary: String) -> [AgentEvent] {
        guard started.insert(id).inserted else { return [] }
        return [.toolStarted(id: id, name: name, summary: summary.firstLine.truncated(to: 200))]
    }

    /// `/bin/zsh -lc 'ls -la'` → `ls -la`.
    static func unwrapShell(_ command: String) -> String {
        guard let match = command.wholeMatch(of: /(?:\/usr)?\/bin\/(?:ba|z)?sh -lc '(.*)'/.dotMatchesNewlines()) else { return command }
        return String(match.1).replacingOccurrences(of: "'\\''", with: "'")
    }

    private static func mcpOutput(_ result: Any?) -> String {
        guard let result = result as? JSONObject else { return JSONLine.compact(result) }
        if let content = result["content"] as? [JSONObject] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return JSONLine.compact(result)
    }
}
