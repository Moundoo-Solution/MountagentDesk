import Foundation

/// Drives `claude -p` with stream-json on both stdin and stdout. The prompt goes in as a
/// user message, and stdin stays open so permission prompts (`can_use_tool` control
/// requests) can be answered while the turn runs, as the Agent SDK does.
public struct ClaudeProvider: AgentProvider {
    public let kind = AgentKind.claude

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        var args = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
        ]
        switch request.access {
        case .readOnly: args += ["--permission-mode", "plan"]
        case .editFiles: args += ["--permission-mode", "acceptEdits"]
        case .fullAccess: args += ["--dangerously-skip-permissions"]
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
            args += ["--resume", resume]
        }
        if request.linksServers {
            // Deny rules hold even with --dangerously-skip-permissions.
            args += ["--disallowedTools", ServerHelper.claudeDenyRules]
        }
        if request.readsServers {
            // The helper checks every command itself, so it needn't ask first.
            args += ["--allowedTools", "Bash(\(ServerHelper.commandName):*)"]
        }
        if let title = request.sessionTitle {
            args += ["--append-system-prompt", SessionTitle.note(for: title)]
        }
        var environment: [String: String] = [:]
        if request.loadsAdditionalRules, !request.additionalDirectories.isEmpty {
            // Off by default in Claude Code: CLAUDE.md in --add-dir folders is otherwise ignored.
            environment["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] = "1"
        }
        // Images go in as content blocks before the text, as when pasting into Claude Code.
        var content: [JSONObject] = request.images.compactMap(Self.imageBlock)
        content.append(["type": "text", "text": request.prompt])
        let message: JSONObject = ["type": "user", "message": ["role": "user", "content": content.count == 1 ? request.prompt as Any : content]]
        return AgentInvocation(arguments: args, stdin: JSONLine.encode(message), keepsStdinOpen: true, environment: environment)
    }

    public func makeParser() -> any AgentStreamParser { ClaudeStreamParser() }

    static func imageBlock(_ url: URL) -> JSONObject? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mediaType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: mediaType = "image/png"
        }
        return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    public func reply(_ reply: PermissionReply, to request: PermissionRequest) -> String? {
        let payload = JSONLine.object(request.payload) ?? [:]
        var decision: JSONObject
        switch reply {
        case .allow, .allowAlways:
            decision = ["behavior": "allow", "updatedInput": payload["input"] ?? [:]]
            if reply == .allowAlways, let suggestions = payload["suggestions"] as? [JSONObject], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": "The user declined this action in Mountagent Desk."]
        }
        return JSONLine.encode([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": request.id, "response": decision],
        ])
    }
}

public struct ClaudeStreamParser: AgentStreamParser {
    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }
        // Subagent traffic is nested under a parent tool call; the parent's row covers it.
        if object["parent_tool_use_id"] is String { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.sessionStarted(id: id, model: object["model"] as? String)]

        case "stream_event":
            return streamEvent(object["event"] as? JSONObject ?? [:])

        case "assistant":
            let blocks = (object["message"] as? JSONObject)?["content"] as? [JSONObject] ?? []
            return blocks.compactMap { block in
                switch block["type"] as? String {
                case "text":
                    return .textSnapshot(block["text"] as? String ?? "")
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    return .toolStarted(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: Self.displayName(name),
                        summary: Self.summary(name: name, input: block["input"] as? JSONObject ?? [:])
                    )
                default:
                    return nil
                }
            }

        case "user":
            let blocks = (object["message"] as? JSONObject)?["content"] as? [JSONObject] ?? []
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id, output: Self.text(of: block["content"]), isError: block["is_error"] as? Bool ?? false)
            }

        case "control_request":
            return controlRequest(object)

        case "rate_limit_event":
            let info = object["rate_limit_info"] as? JSONObject ?? [:]
            let windows = (info["unifiedWindows"] as? [String: JSONObject] ?? [:])
                .map { name, window in
                    RateLimitInfo.Window(
                        name: name,
                        utilization: (window["utilization"] as? Double) ?? Double(window["utilization"] as? Int ?? 0),
                        resetsAt: (window["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    )
                }
                .sorted { $0.name < $1.name }
            guard !windows.isEmpty else { return [] }
            return [.rateLimit(RateLimitInfo(windows: windows))]

        case "result":
            let usage = object["usage"] as? JSONObject ?? [:]
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { usage[$0] as? Int }
                .reduce(0, +)
            return [.completed(TurnResult(
                isError: object["is_error"] as? Bool ?? (object["subtype"] as? String != "success"),
                text: object["result"] as? String,
                durationMs: object["duration_ms"] as? Int,
                costUSD: object["total_cost_usd"] as? Double,
                inputTokens: usage.isEmpty ? nil : input,
                outputTokens: usage["output_tokens"] as? Int
            ))]

        default:
            return []
        }
    }

    private func controlRequest(_ object: JSONObject) -> [AgentEvent] {
        guard let id = object["request_id"] as? String else { return [] }
        let request = object["request"] as? JSONObject ?? [:]
        guard request["subtype"] as? String == "can_use_tool" else {
            // Anything else the CLI asks of an SDK host is refused rather than left hanging.
            return [.reply(JSONLine.encode([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": id, "error": "Not supported by Mountagent Desk"],
            ]))]
        }
        let name = request["tool_name"] as? String ?? "Tool"
        let input = request["input"] as? JSONObject ?? [:]
        // "Always allow" saves only the suggested rules, not mode or directory changes.
        let rules = (request["permission_suggestions"] as? [JSONObject] ?? []).filter { $0["type"] as? String == "addRules" }
        let ruleNames = rules.flatMap { $0["rules"] as? [JSONObject] ?? [] }.map { rule -> String in
            let tool = rule["toolName"] as? String ?? name
            if let content = rule["ruleContent"] as? String, !content.isEmpty { return "\(tool)(\(content))" }
            return tool
        }
        return [.permissionRequest(PermissionRequest(
            id: id,
            toolName: Self.displayName(name),
            summary: Self.summary(name: name, input: input),
            detail: JSONLine.pretty(input),
            alwaysRule: ruleNames.isEmpty ? nil : ruleNames.joined(separator: ", "),
            payload: JSONLine.encode(["input": input, "suggestions": rules])
        ))]
    }

    private func streamEvent(_ event: JSONObject) -> [AgentEvent] {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? JSONObject
            return block?["type"] as? String == "text" ? [.textBlockStarted] : []
        case "content_block_delta":
            let delta = event["delta"] as? JSONObject ?? [:]
            switch delta["type"] as? String {
            case "text_delta": return [.textDelta(delta["text"] as? String ?? "")]
            case "thinking_delta": return [.thinkingDelta(delta["thinking"] as? String ?? "")]
            default: return []
            }
        default:
            return []
        }
    }

    /// `mcp__server__tool` is shown as `MCP`, with the server and tool in the summary.
    static func displayName(_ name: String) -> String {
        name.hasPrefix("mcp__") ? "MCP" : name
    }

    static func summary(name: String, input: JSONObject) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
            let target = parts.joined(separator: " · ")
            return input.isEmpty ? target : "\(target) \(JSONLine.compact(input))".truncated(to: 200)
        }
        for key in ["file_path", "command", "pattern", "path", "url", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty {
                return value.firstLine.truncated(to: 200)
            }
        }
        return JSONLine.compact(input).truncated(to: 200)
    }

    /// Tool results are either a string or a list of content blocks.
    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let blocks = content as? [JSONObject] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return JSONLine.compact(content)
    }
}
