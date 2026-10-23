import Foundation

/// Drives GitHub Copilot CLI: `copilot -p … --output-format json` (JSONL events).
///
/// Copilot can't ask anyone when it runs headless. Without `--allow-all-tools` it still runs
/// file reads and read-only commands, and refuses the rest with a `denied` error, which
/// becomes `.toolBlocked` so the user can let it run on a retry. Access maps onto that:
/// read-only also refuses writes, "ask for commands" allows writes, full access allows all.
/// The GitHub account comes from `COPILOT_GITHUB_TOKEN`, which the app sets.
public struct CopilotProvider: AgentProvider {
    public let kind = AgentKind.copilot

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        // `=` keeps the list-taking options from swallowing the next argument.
        var args = ["--output-format", "json", "--stream", "on", "--no-ask-user", "--no-auto-update", "--no-color",
                    // The account's token stays out of the commands Copilot runs.
                    "--secret-env-vars=\(Self.tokenVariable)"]
        switch request.access {
        case .readOnly: args.append("--deny-tool=write")
        case .editFiles: args.append("--allow-tool=write")
        case .fullAccess: args.append("--allow-all")
        }
        if request.linksServers {
            // Deny rules win over every allow, --allow-all included.
            args += ServerHelper.copilotDenyRules
        }
        if request.readsServers {
            args.append("--allow-tool=shell(\(ServerHelper.commandName):*)")
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        if let effort = request.effort, !effort.isEmpty {
            args += ["--reasoning-effort", effort]
        }
        for directory in request.additionalDirectories {
            args += ["--add-dir", directory.path]
        }
        for image in request.images {
            args += ["--attachment", image.path]
        }
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]
        }
        // Copilot reads AGENTS.md in the working folder itself; the other folders' rules
        // come with the first message, as for Cursor.
        let prompt = request.promptWithContext(listingImages: false)
        args += ["-p", prompt.hasPrefix("-") ? " " + prompt : prompt]
        return AgentInvocation(arguments: args, stdin: nil)
    }

    public func makeParser() -> any AgentStreamParser { CopilotStreamParser() }

    /// Copilot signs in with this token when it is set (a `gh` account's OAuth token works).
    public static let tokenVariable = "COPILOT_GITHUB_TOKEN"

    /// The models `copilot help config` lists under `model`, after an Auto entry.
    public static func parseModels(_ help: String) -> [AgentModel] {
        var models = [AgentModel(id: nil, name: "Auto")]
        var inModels = false
        for line in help.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("`model`:") {
                inModels = true
            } else if inModels {
                guard trimmed.hasPrefix("- \"") else { break }
                let id = trimmed.dropFirst(3).prefix { $0 != "\"" }
                models.append(AgentModel(id: String(id), name: displayName(ofModel: String(id))))
            }
        }
        return models
    }

    /// `claude-sonnet-5.5` → `Claude Sonnet 5.5`, `gpt-6-luna` → `GPT-6 Luna`.
    static func displayName(ofModel id: String) -> String {
        var words = id.split(separator: "-").map(String.init)
        if words.first == "gpt", words.count > 1 {
            words[0] = "GPT-" + words.remove(at: 1)
        }
        return words.map { word in
            word.first?.isLetter == true && !word.hasPrefix("GPT") ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// `copilot --version`: "GitHub Copilot CLI 1.0.102." → "1.0.102".
    public static func parseVersion(_ output: String) -> String? {
        output.firstMatch(of: /(\d+\.\d+\.\d+)/).map { String($0.1) }
    }
}

/// Copilot's JSONL events. Text streams as `assistant.message_delta` and arrives whole as
/// `assistant.message`; tools run between `tool.execution_start` and `…_complete`; the
/// session id only comes with the closing `result` line.
public struct CopilotStreamParser: AgentStreamParser {
    /// The message whose text block is open, and what was streamed into it.
    private var messageID: String?
    private var streamed = ""
    private var lastMessage: String?
    private var model: String?
    private var tools: [String: (name: String, summary: String)] = [:]

    public init() {}

    /// Bookkeeping tools that do nothing the user needs to see.
    static let hiddenTools: Set<String> = ["report_intent"]

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        let data = object["data"] as? JSONObject ?? [:]
        switch type {
        case "assistant.message_delta":
            guard let delta = data["deltaContent"] as? String, !delta.isEmpty else { return [] }
            let id = data["messageId"] as? String
            if id != messageID || messageID == nil {
                messageID = id
                streamed = delta
                return [.textBlockStarted, .textDelta(delta)]
            }
            streamed += delta
            return [.textDelta(delta)]

        case "assistant.message":
            model = data["model"] as? String ?? model
            guard let content = data["content"] as? String, !content.isEmpty else { return [] }
            lastMessage = content
            let id = data["messageId"] as? String
            if id != nil, id == messageID {
                return content == streamed ? [] : [.textSnapshot(content)]
            }
            messageID = id
            streamed = content
            return [.textBlockStarted, .textDelta(content)]

        case "assistant.reasoning_delta":
            guard let delta = data["deltaContent"] as? String, !delta.isEmpty else { return [] }
            return [.thinkingDelta(delta)]

        case "tool.execution_start":
            let tool = data["toolName"] as? String ?? "tool"
            guard let id = data["toolCallId"] as? String, !Self.hiddenTools.contains(tool) else { return [] }
            let (name, summary) = Self.describe(tool: tool, arguments: data["arguments"])
            tools[id] = (name, summary)
            messageID = nil
            return [.toolStarted(id: id, name: name, summary: summary)]

        case "tool.execution_complete":
            guard let id = data["toolCallId"] as? String, let tool = tools[id] else { return [] }
            let success = data["success"] as? Bool ?? true
            let error = data["error"] as? JSONObject
            let exitCode = (data["shellExecution"] as? JSONObject)?["exitCode"] as? Int
            let output = (error?["message"] as? String) ?? Self.output(of: data)
            var events: [AgentEvent] = [.toolFinished(id: id, output: output, isError: !success || (exitCode ?? 0) != 0)]
            // Refused for want of someone to ask (not by a deny rule): it can be let through on a retry.
            if error?["code"] as? String == "denied", !(error?["message"] as? String ?? "").contains("following rules") {
                events.append(.toolBlocked(BlockedTool(callID: id, toolName: tool.name, summary: tool.summary, rule: nil)))
            }
            return events

        case "session.error":
            return [.failure(data["message"] as? String ?? "Copilot reported an error.")]

        case "result":
            let usage = object["usage"] as? JSONObject ?? [:]
            var events: [AgentEvent] = []
            if let id = object["sessionId"] as? String {
                events.append(.sessionStarted(id: id, model: model))
            }
            events.append(.completed(TurnResult(
                isError: (object["exitCode"] as? Int ?? 0) != 0,
                text: lastMessage,
                durationMs: usage["sessionDurationMs"] as? Int
            )))
            return events

        default:
            return []
        }
    }

    /// The transcript's tool name and one-line summary for a Copilot tool call.
    static func describe(tool: String, arguments: Any?) -> (String, String) {
        let args = arguments as? JSONObject ?? [:]
        func value(_ keys: String...) -> String {
            for key in keys {
                if let text = args[key] as? String, !text.isEmpty { return text.firstLine.truncated(to: 200) }
            }
            return ""
        }
        switch tool {
        case "bash", "shell", "powershell", "read_bash", "write_bash":
            return ("Shell", value("command", "input"))
        case "view", "read", "read_file":
            return ("Read", value("path"))
        case "create", "write":
            return ("Write", value("path"))
        case "edit", "str_replace", "str_replace_editor":
            return ("Edit", value("path"))
        case "apply_patch":
            let files = patchFiles(arguments as? String ?? "")
            return ("Edit", files.count == 1 ? files[0] : "\(files.count) files")
        case "grep", "rg", "search":
            return ("Grep", value("pattern", "query"))
        case "glob":
            return ("Glob", value("pattern"))
        case "web_fetch", "fetch":
            return ("WebFetch", value("url"))
        case "web_search":
            return ("WebSearch", value("query"))
        case "task", "agent":
            return ("Agent", value("description", "prompt"))
        default:
            // MCP tools are named `<server>-<tool>`.
            let summary = value("description", "query", "path")
            return tool.contains("-") ? ("MCP", tool + (summary.isEmpty ? "" : " · " + summary)) : (tool, summary)
        }
    }

    /// The files an `apply_patch` call touches.
    static func patchFiles(_ patch: String) -> [String] {
        patch.components(separatedBy: .newlines).compactMap { line in
            guard let match = line.firstMatch(of: /^\*\*\* (?:Update|Add|Delete) File: (.+)$/) else { return nil }
            return String(match.1)
        }
    }

    /// A finished tool's output without Copilot's `<shellId: …>` trailer; edits list their files.
    static func output(of data: JSONObject) -> String {
        if let edits = data["fileEdits"] as? [JSONObject], !edits.isEmpty {
            return edits.map { "\($0["kind"] as? String ?? "edit") \($0["path"] as? String ?? "")" }.joined(separator: "\n")
        }
        let content = (data["result"] as? JSONObject)?["content"] as? String ?? ""
        return content.replacingOccurrences(of: #"\n?<shellId: [^>]*>\s*$"#, with: "", options: .regularExpression)
    }
}
