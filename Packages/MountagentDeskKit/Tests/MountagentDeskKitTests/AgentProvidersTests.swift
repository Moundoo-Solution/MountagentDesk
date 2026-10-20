import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct CodexProviderTests {
    @Test func replaysACommandTurn() throws {
        let (session, reducer) = replay(try fixtureLines("codex-edit"), parser: CodexStreamParser(), agent: .codex)
        #expect(session.agentSessionIDs[.codex] == "01a159a5-77b9-7d71-b220-7ea0f8db5bae")

        let tools = session.items.filter { $0.kind == .tool }
        #expect(tools.count == 1)
        #expect(tools.first?.toolName == "Shell")
        #expect(tools.first?.text == "pwd && printf hi > hello.txt && ls", "the zsh -lc wrapper is dropped")
        #expect(tools.first?.toolStatus == .succeeded)
        #expect(tools.first?.toolOutput?.contains("hello.txt") == true)

        let texts = session.items.filter { $0.kind == .assistant }.map(\.text)
        #expect(texts.first?.contains("hello.txt") == true)
        #expect(texts.last == "done")
        #expect(!session.items.contains { $0.text.contains("deprecated") }, "config warnings stay out of the chat")

        #expect(reducer.lastResult?.isError == false)
        #expect(reducer.lastResult?.text == "done")
        #expect(reducer.lastResult?.inputTokens == 31474)
    }

    @Test func replaysAResumedEditWithReasoning() throws {
        let (session, reducer) = replay(try fixtureLines("codex-resume"), parser: CodexStreamParser(), agent: .codex)
        #expect(session.items.contains { $0.kind == .thinking })
        let edit = try #require(session.items.first { $0.toolName == "Edit" })
        #expect(edit.text == "/tmp/agentdesk-fixture/README.md")
        #expect(edit.toolStatus == .succeeded)
        #expect(reducer.lastResult?.outputTokens == 300 + 147, "reasoning tokens count as output")
    }

    @Test func buildsArgumentsForNewAndResumedTurns() {
        var request = AgentRunRequest(prompt: "-fix it", workingDirectory: URL(fileURLWithPath: "/repo"),
                                      additionalDirectories: [URL(fileURLWithPath: "/other")],
                                      model: "gpt-5.6-terra", effort: "high", access: .editFiles, resumeSessionID: nil)
        request.images = [URL(fileURLWithPath: "/tmp/shot.png")]
        let first = CodexProvider().invocation(for: request)
        #expect(first.arguments.prefix(2) == ["exec", "--json"])
        #expect(first.arguments.contains("sandbox_mode=\"workspace-write\""))
        #expect(first.arguments.contains("sandbox_workspace_write.writable_roots=[\"/other\"]"))
        #expect(first.arguments.contains("model_reasoning_effort=\"high\""))
        #expect(first.arguments.suffix(3) == ["-C", "/repo", "-"])
        #expect(first.arguments.contains("-i"))
        #expect(first.stdin == "-fix it", "the prompt goes in on stdin, so a leading dash is safe")

        request.resumeSessionID = "abc"
        request.access = .fullAccess
        let next = CodexProvider().invocation(for: request)
        #expect(next.arguments.prefix(3) == ["exec", "resume", "--json"])
        #expect(next.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(next.arguments.suffix(2) == ["abc", "-"])
        #expect(!next.arguments.contains("-C"), "resume has no --cd; the process runs in the folder")
    }

    @Test func listsModelsWithTheirEfforts() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-models", withExtension: "json", subdirectory: "Fixtures"))
        let models = CodexProvider.parseModels(try String(contentsOf: url, encoding: .utf8))
        #expect(models.map(\.model.id) == ["gpt-6-luna", "gpt-5.6-terra", "gpt-5.6-luna"], "hidden models are left out, Codex's order kept")
        #expect(models[1].efforts.last == "ultra")
        #expect(models[0].defaultEffort == "medium")
    }

    @Test func readsLoginStatus() {
        var account = AgentAccount(kind: .codex)
        AccountProbe.applyCodexStatus("Logged in using ChatGPT\n", to: &account)
        #expect(account.loggedIn)
        #expect(account.plan == "ChatGPT")
        AccountProbe.applyCodexStatus("Not logged in\n", to: &account)
        #expect(!account.loggedIn)
    }
}

@Suite struct AntigravityProviderTests {
    @Test func buildsArguments() {
        var request = AgentRunRequest(prompt: "-x", workingDirectory: URL(fileURLWithPath: "/repo"), model: "fast", effort: "high", access: .editFiles, resumeSessionID: nil)
        let first = AntigravityProvider().invocation(for: request)
        #expect(first.arguments.prefix(3) == ["-p", "--output-format", "stream-json"])
        #expect(first.arguments.contains("accept-edits"))
        #expect(first.arguments.suffix(2) == ["--", "-x"], "after --, a leading dash stays part of the prompt")

        request.resumeSessionID = "c1"
        request.access = .fullAccess
        let next = AntigravityProvider().invocation(for: request)
        #expect(next.arguments.contains("--dangerously-skip-permissions"))
        #expect(Array(next.arguments.drop { $0 != "--conversation" }.prefix(2)) == ["--conversation", "c1"])
    }

    /// The closing event, as `agy -p --output-format stream-json` printed it when sign-in failed.
    @Test func readsTheResult() {
        var parser = AntigravityStreamParser()
        let failed = parser.parse(line: #"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0}}}"#)
        #expect(failed == [.completed(TurnResult(isError: true, text: "authentication failed or timed out", durationMs: 0, inputTokens: 0, outputTokens: 0))])
    }

    @Test func findsTheSignInLinkInTerminalOutput() throws {
        let flow = try #require(AgentSetup.signInFlow(for: .antigravity))
        let output = "\u{1B}[?1049h\u{1B}[2J\u{1B}[HOpening browser to authenticate with Google...\r\n"
            + "https://accounts.google.com/o/oauth2/v2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8085&access_type=offline&state=abc\r\n\r\nOr, paste the authorization code here and press Enter: "
        let link = try #require(AgentSetup.link(in: output, prefix: flow.linkPrefix))
        #expect(link.host == "accounts.google.com")
        #expect(link.absoluteString.hasSuffix("state=abc"))
        #expect(output.contains(flow.codePrompt))
        #expect(AgentSetup.link(in: "https://accounts.google.com/o/oauth2/v2/auth?state=ab", prefix: flow.linkPrefix) == nil, "a link still arriving isn't opened half-way")
    }
}

@Suite struct SetupCommandTests {
    @Test func signsInRightAfterInstalling() {
        // No executable yet: the bare name, found on the terminal's PATH wherever it installed.
        #expect(AgentSetup.loginCommand(for: .codex, executable: nil) == "codex login")
        #expect(AgentSetup.loginCommand(for: .claude, executable: "/Users/me/.local/bin/claude") == "'/Users/me/.local/bin/claude' auth login")
        #expect(AgentSetup.logoutCommand(for: .antigravity, executable: nil) == nil, "agy has no sign-out command")
    }
}
