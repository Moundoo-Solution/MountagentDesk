import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ClaudeParserTests {
    @Test func replaysReadTurn() throws {
        let (session, reducer) = replay(try fixtureLines("claude-read"), parser: ClaudeStreamParser(), agent: .claude)

        #expect(session.agentSessionIDs[.claude] == "2e5393bc-20bf-4847-af76-56f0b4f5feb9")

        let tools = session.items.filter { $0.kind == .tool }
        #expect(tools.count == 1)
        #expect(tools.first?.toolName == "Read")
        #expect(tools.first?.text.hasSuffix("a.txt") == true)
        #expect(tools.first?.toolStatus == .succeeded)
        #expect(tools.first?.toolOutput?.contains("hello") == true)

        let texts = session.items.filter { $0.kind == .assistant }
        #expect(texts.count == 1, "streamed deltas and the final snapshot must land in one row")
        #expect(texts.first?.text.contains("**hello**") == true)

        #expect(reducer.lastResult?.isError == false)
        #expect(reducer.lastResult?.costUSD != nil)
    }

    @Test func buildsArguments() {
        let request = AgentRunRequest(prompt: "-x", workingDirectory: URL(fileURLWithPath: "/tmp"), model: "opus", access: .fullAccess, resumeSessionID: "abc")
        let invocation = ClaudeProvider().invocation(for: request)
        let message = JSONLine.object(invocation.stdin ?? "")?["message"] as? JSONObject
        #expect(message?["content"] as? String == "-x")
        #expect(invocation.arguments.contains("--dangerously-skip-permissions"))
        #expect(invocation.arguments.suffix(4) == ["--model", "opus", "--resume", "abc"])
    }
}

@Suite struct CursorParserTests {
    @Test func replaysMultiSegmentTurn() throws {
        let (session, reducer) = replay(try fixtureLines("cursor-multi"), parser: CursorStreamParser(), agent: .cursor)

        #expect(session.agentSessionIDs[.cursor] == "a85af8f0-26d6-4048-94e8-f049603000f8")

        let kinds = session.items.map(\.kind).filter { $0 != .thinking }
        #expect(kinds == [.assistant, .tool, .assistant])

        let texts = session.items.filter { $0.kind == .assistant }.map(\.text)
        #expect(texts == ["Starting now.\n", "`a.txt` contains a single line: **hello**."])

        let tool = try #require(session.items.first { $0.kind == .tool })
        #expect(tool.toolName == "Read")
        #expect(tool.toolStatus == .succeeded)
        #expect(reducer.lastResult?.isError == false)
    }

    @Test func buildsArguments() {
        let request = AgentRunRequest(prompt: "-x", workingDirectory: URL(fileURLWithPath: "/tmp/p"), model: nil, access: .readOnly, resumeSessionID: nil)
        let args = CursorProvider().invocation(for: request).arguments
        #expect(args.contains("--trust"))
        #expect(args.contains("plan"))
        #expect(!args.contains("--model"))
        #expect(args.last == " -x")
    }

    @Test func parsesModelList() {
        let output = "Available models\n\nauto - Auto (current, default)\ngpt-5.2 - GPT-5.2\ngrok-4.7-low-fast - Grok 4.7  Low Fast\u{200B}\u{200B}\n"
        let models = CursorProvider.parseModels(output)
        #expect(models.map(\.id) == [nil, "gpt-5.2", "grok-4.7-low-fast"])
        #expect(models.last?.name == "Grok 4.7  Low Fast")
    }
}

@Suite struct PromptBuilderTests {
    @Test func handsOffEarlierTurns() {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        session.items = [
            ChatItem(kind: .user, text: "Fix the bug"),
            ChatItem(kind: .assistant, agent: .claude, text: "Done, see foo.py"),
        ]
        session.agentSessionIDs[.claude] = "x"
        session.seenCounts[.claude] = 2
        #expect(session.unseenItems(for: .claude).isEmpty)
        #expect(session.unseenItems(for: .cursor).count == 2)

        // Cursor answers a turn; Claude must now hear about it, but not about its own turn.
        session.items += [ChatItem(kind: .user, text: "Add docs"), ChatItem(kind: .assistant, agent: .cursor, text: "Added")]
        #expect(session.unseenItems(for: .claude).map(\.text) == ["Add docs", "Added"])

        let prompt = PromptBuilder.prompt("Now add a test", attachments: ["foo.py"], missed: session.unseenItems(for: .cursor))
        #expect(prompt.contains("User: Fix the bug"))
        #expect(prompt.contains("Claude Code: Done, see foo.py"))
        #expect(prompt.hasSuffix("Files to look at:\n- foo.py"))
    }
}

@Suite struct ReducerTests {
    @Test func skipsEmptyThinking() {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        var reducer = TranscriptReducer(agent: .claude)
        reducer.apply(.thinkingDelta(""), to: &session)
        reducer.apply(.textDelta("Hi"), to: &session)
        #expect(session.items.map(\.kind) == [.assistant])
    }
}
