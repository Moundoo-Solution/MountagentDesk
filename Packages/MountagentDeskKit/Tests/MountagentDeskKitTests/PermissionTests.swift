import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ClaudePermissionTests {
    @Test func parsesCanUseToolAndAnswersIt() throws {
        var parser = ClaudeStreamParser()
        let requests = try fixtureLines("claude-permission").flatMap { parser.parse(line: $0) }.compactMap { event -> PermissionRequest? in
            if case .permissionRequest(let request) = event { return request }
            return nil
        }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.toolName == "Bash")
        #expect(request.summary == #"python3 -c "print(6*7)""#)
        #expect(request.alwaysRule?.hasPrefix("Bash(") == true)

        let provider = ClaudeProvider()
        let allow = try #require(JSONLine.object(provider.reply(.allow, to: request) ?? ""))
        let response = try #require((allow["response"] as? JSONObject)?["response"] as? JSONObject)
        #expect((allow["response"] as? JSONObject)?["request_id"] as? String == request.id)
        #expect(response["behavior"] as? String == "allow")
        #expect((response["updatedInput"] as? JSONObject)?["command"] as? String == #"python3 -c "print(6*7)""#)
        #expect(response["updatedPermissions"] == nil)

        let always = try #require(JSONLine.object(provider.reply(.allowAlways, to: request) ?? ""))
        let rules = ((always["response"] as? JSONObject)?["response"] as? JSONObject)?["updatedPermissions"] as? [JSONObject]
        #expect(rules?.count == 1)
        #expect(rules?.first?["type"] as? String == "addRules")

        let deny = try #require(JSONLine.object(provider.reply(.deny, to: request) ?? ""))
        #expect(((deny["response"] as? JSONObject)?["response"] as? JSONObject)?["behavior"] as? String == "deny")
    }

    @Test func refusesUnknownControlRequests() {
        var parser = ClaudeStreamParser()
        let events = parser.parse(line: #"{"type":"control_request","request_id":"r1","request":{"subtype":"hook_callback"}}"#)
        guard case .reply(let line) = events.first else {
            Issue.record("expected a reply")
            return
        }
        #expect(line.contains(#""subtype":"error""#))
        #expect(line.contains(#""request_id":"r1""#))
    }

    @Test func expiresUnansweredRequests() throws {
        var parser = ClaudeStreamParser()
        var reducer = TranscriptReducer(agent: .claude)
        var session = ChatSession(projectID: UUID(), agent: .claude)
        for line in try fixtureLines("claude-permission") {
            for event in parser.parse(line: line) { reducer.apply(event, to: &session) }
        }
        let row = try #require(session.items.first { $0.kind == .permission })
        #expect(row.permissionState == .expired)
        #expect(session.items.last { $0.kind == .assistant }?.text.contains("42") == true)
    }

    @Test func sendsSessionTitleAndKeepsStdinOpen() {
        let request = AgentRunRequest(prompt: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, access: .editFiles, resumeSessionID: nil, sessionTitle: "8239 - Fix")
        let invocation = ClaudeProvider().invocation(for: request)
        #expect(invocation.keepsStdinOpen)
        #expect(invocation.arguments.contains("stdio"))
        let note = invocation.arguments.drop { $0 != "--append-system-prompt" }.dropFirst().first
        #expect(note?.contains(#""8239 - Fix""#) == true)
        #expect(JSONLine.object(invocation.stdin ?? "")?["type"] as? String == "user")
    }
}

@Suite struct MCPNameTests {
    @Test func showsClaudeMCPToolsReadably() {
        #expect(ClaudeStreamParser.displayName("mcp__helpdesk__sync_ticket") == "MCP")
        #expect(ClaudeStreamParser.summary(name: "mcp__helpdesk__whoami", input: [:]) == "helpdesk · whoami")
        #expect(ClaudeStreamParser.summary(name: "mcp__helpdesk__sync_ticket", input: ["ticket_id": 8239]) == #"helpdesk · sync_ticket {"ticket_id":8239}"#)
    }
}

@Suite struct CursorPermissionTests {
    @Test func reportsRejectedCallsWithRules() throws {
        var parser = CursorStreamParser()
        var reducer = TranscriptReducer(agent: .cursor)
        var session = ChatSession(projectID: UUID(), agent: .cursor)
        var blocked: [BlockedTool] = []
        for line in try fixtureLines("cursor-rejected") {
            for event in parser.parse(line: line) {
                if case .toolBlocked(let tool) = event { blocked.append(tool) }
                reducer.apply(event, to: &session)
            }
        }
        #expect(Set(blocked.compactMap(\.rule)) == ["Mcp(helpdesk:whoami)", "Shell(touch)"])
        let rows = session.items.filter { $0.kind == .permission }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.permissionState == .blocked })
        #expect(session.items.contains { $0.kind == .tool && $0.toolName == "MCP" && $0.text == "helpdesk · whoami" && $0.toolStatus == .failed })
    }

    @Test func editsCliJsonAndKeepsOtherKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskPerm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try #"{"editor":{"vimMode":true},"permissions":{"allow":["Shell(ls)"],"deny":["Shell(rm)"]}}"#
            .write(to: root.appendingPathComponent(".cursor/cli.json"), atomically: true, encoding: .utf8)

        #expect(try CursorPermissions.allow("Mcp(helpdesk:*)", in: root))
        #expect(try !CursorPermissions.allow("Mcp(helpdesk:*)", in: root))
        #expect(CursorPermissions.allowedRules(in: root) == ["Shell(ls)", "Mcp(helpdesk:*)"])

        try CursorPermissions.revoke("Shell(ls)", in: root)
        let text = try String(contentsOf: root.appendingPathComponent(".cursor/cli.json"), encoding: .utf8)
        #expect(text.contains("vimMode"))
        #expect(text.contains("Shell(rm)"))
        #expect(CursorPermissions.allowedRules(in: root) == ["Mcp(helpdesk:*)"])
    }

    @Test func removesTheFileItCreatedOnceEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskPerm-\(UUID().uuidString)")
        try CursorPermissions.allow("Shell(make)", in: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".cursor/cli.json").path))
        try CursorPermissions.revoke("Shell(make)", in: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".cursor/cli.json").path))
    }

    @Test func prefixesSessionNote() {
        let request = AgentRunRequest(prompt: "sync", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, access: .editFiles, resumeSessionID: "x", sessionTitle: "8239 - Fix")
        let prompt = CursorProvider().invocation(for: request).arguments.last ?? ""
        #expect(prompt.hasPrefix("<mountagent>"))
        #expect(prompt.hasSuffix("</mountagent>\n\nsync"))
    }
}

@Suite struct SessionTitleTests {
    @Test func extractsAndHidesMarker() {
        let (text, title) = SessionTitle.extract(from: "Synced ticket 8239.\n\nMountagent-Title: 8239 - Replenish products\n")
        #expect(title == "8239 - Replenish products")
        #expect(text == "Synced ticket 8239.")
        #expect(SessionTitle.extract(from: "`Mountagent-Title: \"New\"`").title == "New")
        #expect(SessionTitle.extract(from: "no marker").title == nil)
        #expect(SessionTitle.extract(from: "Done.\nAgentDesk-Title: Old skill") == ("Done.", "Old skill"))
    }

    @Test func reducerRenamesSession() {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        var reducer = TranscriptReducer(agent: .claude)
        reducer.apply(.textDelta("Done.\nMountagent-Title: 8239 - Fix totals"), to: &session)
        reducer.apply(.completed(TurnResult(isError: false)), to: &session)
        #expect(session.title == "8239 - Fix totals")
        #expect(session.items.last?.text == "Done.")
    }
}

@Suite struct ImageInputTests {
    private func image() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mountagent-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: url)
        return url
    }

    @Test func claudeGetsImageBlocksBeforeTheText() throws {
        let url = try image()
        var request = AgentRunRequest(prompt: "What is this?", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, access: .editFiles, resumeSessionID: nil)
        request.images = [url]
        let stdin = try #require(ClaudeProvider().invocation(for: request).stdin)
        let message = try #require(JSONLine.object(stdin)?["message"] as? JSONObject)
        let content = try #require(message["content"] as? [JSONObject])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? JSONObject)
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).base64EncodedString())

        request.images = []
        let plain = JSONLine.object(ClaudeProvider().invocation(for: request).stdin ?? "")?["message"] as? JSONObject
        #expect(plain?["content"] as? String == "What is this?")
    }

    @Test func cursorGetsImagePaths() throws {
        let url = try image()
        var request = AgentRunRequest(prompt: "What is this?", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, access: .editFiles, resumeSessionID: nil)
        request.images = [url]
        let prompt = CursorProvider().invocation(for: request).arguments.last ?? ""
        #expect(prompt.hasPrefix("What is this?"))
        #expect(prompt.contains("- \(url.path)"))
    }
}
