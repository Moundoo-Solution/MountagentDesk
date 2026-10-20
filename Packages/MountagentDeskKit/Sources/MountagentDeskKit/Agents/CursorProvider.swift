import Foundation

/// Drives `cursor-agent -p` with `--output-format stream-json`.
public struct CursorProvider: AgentProvider {
    public let kind = AgentKind.cursor

    public init() {}

    public func invocation(for request: AgentRunRequest) -> AgentInvocation {
        var args = [
            "-p", "--output-format", "stream-json", "--stream-partial-output",
            "--trust", "--workspace", request.workingDirectory.path,
        ]
        switch request.access {
        case .readOnly: args += ["--mode", "plan"]
        case .editFiles: break
        case .fullAccess: args += ["--force"]
        }
        if let model = request.model, !model.isEmpty {
            args += ["--model", model]
        }
        for directory in request.additionalDirectories {
            args += ["--add-dir", directory.path]
        }
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]
        }
        // cursor-agent takes no image input, but its read tool opens image files.
        let prompt = request.promptWithContext(listingImages: true)
        // cursor-agent only takes the prompt as an argument; a leading dash would be read as an option.
        args.append(prompt.hasPrefix("-") ? " " + prompt : prompt)
        return AgentInvocation(arguments: args, stdin: nil)
    }

    public func makeParser() -> any AgentStreamParser { CursorStreamParser() }

    /// Parses `cursor-agent models`, whose lines read `id - Display name`.
    public static func parseModels(_ output: String) -> [AgentModel] {
        let ansi = /\u{1B}\[[0-9;?]*[A-Za-z]/
        var models = [AgentModel(id: nil, name: "Auto")]
        for rawLine in output.replacing(ansi, with: "").components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: " - ") else { continue }
            let id = String(line[..<range.lowerBound])
            guard !id.contains(" "), id != "auto" else { continue }
            let name = line[range.upperBound...]
                .replacingOccurrences(of: "(current, default)", with: "")
                .replacingOccurrences(of: "(current)", with: "")
                .replacingOccurrences(of: "(default)", with: "")
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{200B}")))
            models.append(AgentModel(id: id, name: name))
        }
        return models
    }
}

public struct CursorStreamParser: AgentStreamParser {
    /// Text streamed since the last tool call. cursor-agent mixes deltas with snapshots of
    /// the whole block, and both carry the same shape, so a message that starts with what
    /// was already streamed is treated as a snapshot.
    private var segment = ""

    public init() {}

    public mutating func parse(line: String) -> [AgentEvent] {
        guard let object = JSONLine.object(line), let type = object["type"] as? String else { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init", let id = object["session_id"] as? String else { return [] }
            return [.sessionStarted(id: id, model: object["model"] as? String)]

        case "assistant":
            let blocks = (object["message"] as? JSONObject)?["content"] as? [JSONObject] ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { return [] }
            if !segment.isEmpty, text.hasPrefix(segment) {
                segment = text
                return [.textSnapshot(text)]
            }
            let startsBlock = segment.isEmpty
            segment += text
            return startsBlock ? [.textBlockStarted, .textDelta(text)] : [.textDelta(text)]

        case "thinking":
            guard object["subtype"] as? String == "delta", let text = object["text"] as? String else { return [] }
            return [.thinkingDelta(text)]

        case "tool_call":
            let id = object["call_id"] as? String ?? UUID().uuidString
            let call = object["tool_call"] as? JSONObject ?? [:]
            guard let (key, body) = call.first(where: { $0.key.hasSuffix("ToolCall") }),
                  let body = body as? JSONObject
            else { return [] }
            let args = body["args"] as? JSONObject ?? [:]
            let isMCP = key == "mcpToolCall"
            let name = isMCP ? "MCP" : Self.toolName(fromKey: key)
            let summary = isMCP || key == "getMcpToolsToolCall" ? Self.mcpSummary(args: args) : Self.summary(args: args)
            switch object["subtype"] as? String {
            case "started":
                segment = ""
                return [.toolStarted(id: id, name: name, summary: summary)]
            case "completed":
                let result = body["result"] as? JSONObject
                let (output, isError) = Self.output(of: result)
                var events: [AgentEvent] = [.toolFinished(id: id, output: output, isError: isError)]
                if result?["rejected"] != nil {
                    events.append(.toolBlocked(BlockedTool(callID: id, toolName: name, summary: summary, rule: Self.allowRule(key: key, args: args))))
                }
                return events
            default:
                return []
            }

        case "result":
            let usage = object["usage"] as? JSONObject ?? [:]
            let input = ["inputTokens", "cacheReadTokens", "cacheWriteTokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
            return [.completed(TurnResult(
                isError: object["is_error"] as? Bool ?? (object["subtype"] as? String != "success"),
                text: object["result"] as? String,
                durationMs: object["duration_ms"] as? Int,
                costUSD: nil,
                inputTokens: usage.isEmpty ? nil : input,
                outputTokens: usage["outputTokens"] as? Int
            ))]

        default:
            return []
        }
    }

    /// `readToolCall` → `Read`, `shellToolCall` → `Shell`.
    static func toolName(fromKey key: String) -> String {
        let base = key.dropLast("ToolCall".count)
        return base.prefix(1).uppercased() + base.dropFirst()
    }

    static func summary(args: JSONObject) -> String {
        for key in ["path", "command", "globPattern", "pattern", "query", "url", "targetFile"] {
            if let value = args[key] as? String, !value.isEmpty {
                return value.firstLine.truncated(to: 200)
            }
        }
        return JSONLine.compact(args).truncated(to: 200)
    }

    static func mcpSummary(args: JSONObject) -> String {
        let server = args["serverIdentifier"] as? String ?? args["providerIdentifier"] as? String
        let tool = args["toolName"] as? String ?? args["name"] as? String ?? "tool"
        return [server, tool].compactMap { $0 }.joined(separator: " · ")
    }

    /// The `.cursor/cli.json` permission that lets a refused call run, in cursor-agent's
    /// `Mcp(server:tool)` / `Shell(command)` form.
    static func allowRule(key: String, args: JSONObject) -> String? {
        switch key {
        case "mcpToolCall":
            guard let server = args["serverIdentifier"] as? String ?? args["providerIdentifier"] as? String,
                  let tool = args["toolName"] as? String
            else { return nil }
            return "Mcp(\(server):\(tool))"
        case "shellToolCall":
            let command = (args["simpleCommands"] as? [String])?.first
                ?? (args["command"] as? String)?.split(separator: " ").first.map(String.init)
            return command.map { "Shell(\($0))" }
        default:
            return nil
        }
    }

    static func output(of result: JSONObject?) -> (String, Bool) {
        guard let result else { return ("", false) }
        if let rejected = result["rejected"] as? JSONObject {
            let reason = (rejected["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ("Blocked: " + (reason ?? "needs approval"), true)
        }
        if let error = result["error"] as? JSONObject {
            return (error["errorMessage"] as? String ?? JSONLine.compact(error), true)
        }
        if let success = result["success"] as? JSONObject {
            for key in ["content", "stdout", "output", "diffString"] {
                if let value = success[key] as? String { return (value, false) }
            }
            if let files = success["files"] as? [String] { return (files.joined(separator: "\n"), false) }
            return (JSONLine.compact(success), false)
        }
        return (JSONLine.compact(result), false)
    }
}
