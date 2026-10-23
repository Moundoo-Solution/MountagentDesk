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

/// Neither CLI could run here, so their fixtures are written from each CLI's own output
/// code: Gemini CLI's `JsonStreamEventType` events and OpenCode's `run --format json`.
@Suite struct GeminiProviderTests {
    @Test func replaysATurnWithADeniedCommand() throws {
        let (session, reducer) = replay(try fixtureLines("gemini-edit"), parser: GeminiStreamParser(), agent: .gemini)
        #expect(session.agentSessionIDs[.gemini] == "4b7f0c52-9a1e-4d7b-8f61-2c3d4e5f6a7b")
        let tools = session.items.filter { $0.kind == .tool }
        #expect(tools.map(\.text) == ["/tmp/fixture/README.md", "rm -rf build"])
        #expect(tools.first?.toolStatus == .succeeded)
        #expect(tools.last?.toolStatus == .failed)
        #expect(tools.last?.toolOutput == "Tool execution denied by policy.")
        let texts = session.items.filter { $0.kind == .assistant }.map(\.text)
        #expect(texts == ["Reading the file first.", "Added the line."])
        #expect(reducer.lastResult?.isError == false)
        #expect(reducer.lastResult?.inputTokens == 12000 && reducer.lastResult?.outputTokens == 400)
        #expect(reducer.lastResult?.durationMs == 3100)
    }

    @Test func reportsAFailedRun() throws {
        var parser = GeminiStreamParser()
        let events = parser.parse(line: #"{"type":"result","status":"error","error":{"type":"FatalAuthenticationError","message":"Please set an Auth method"},"stats":{}}"#)
        #expect(events == [.completed(TurnResult(isError: true, text: "Please set an Auth method"))])
        // As a bad API key reported it.
        let nested = try #require(JSONLine.object(#"{"message":"[API Error: {\"error\":{\"message\":\"{\\n  \\\"error\\\": {\\n    \\\"code\\\": 400,\\n    \\\"message\\\": \\\"API key not valid. Please pass a valid API key.\\\",\\n  }\\n}\"}}]"}"#)?["message"] as? String)
        #expect(GeminiStreamParser.readable(nested) == "API key not valid. Please pass a valid API key.")
        #expect(GeminiStreamParser.readable("Quota exceeded") == "Quota exceeded")
    }

    @Test func buildsArguments() {
        var request = AgentRunRequest(prompt: "-fix it", workingDirectory: URL(fileURLWithPath: "/repo"),
                                      additionalDirectories: [URL(fileURLWithPath: "/other")],
                                      model: "gemini-3.1-pro-preview", access: .editFiles, resumeSessionID: nil)
        let first = GeminiProvider().invocation(for: request)
        #expect(first.arguments.contains("auto_edit"))
        #expect(first.arguments.contains("/other"))
        #expect(first.arguments.last == "--prompt=-fix it", "joined to the option, so a leading dash is safe")
        request.resumeSessionID = "abc"
        request.access = .readOnly
        let next = GeminiProvider().invocation(for: request)
        #expect(next.arguments.contains("plan"))
        #expect(next.arguments.firstIndex(of: "--resume").map { next.arguments[$0 + 1] } == "abc")
    }

    @Test func findsHowItSignsIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-\(UUID().uuidString)")
        let folder = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func auth(_ environment: [String: String] = [:], keychain: Set<String> = []) -> String? {
            AccountProbe.geminiAuth(home: home, environment: environment, inKeychain: keychain.contains)
        }
        #expect(auth() == nil)
        #expect(auth(["GEMINI_API_KEY": "k"]) == "Gemini API key")
        #expect(auth(keychain: ["gemini-cli-api-key"]) == "Gemini API key")
        #expect(auth(keychain: ["gemini-cli-oauth"]) == "Google account")
        try "GEMINI_API_KEY=\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(auth() == nil, "an empty key signs nobody in")
        try "export GEMINI_API_KEY=k\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        #expect(auth() == "Gemini API key")
    }
}

@Suite struct OpenCodeProviderTests {
    @Test func replaysATurnAndEndsItWithTheProcess() throws {
        let (session, reducer) = replay(try fixtureLines("opencode-edit"), parser: OpenCodeStreamParser(), agent: .opencode)
        #expect(session.agentSessionIDs[.opencode] == "ses_5f2a9c1e7ffeA1b2C3d4E5f6")
        #expect(session.items.contains { $0.kind == .thinking })
        let tools = session.items.filter { $0.kind == .tool }
        #expect(tools.map(\.text) == ["/tmp/fixture/README.md", "git push"])
        #expect(tools.last?.toolStatus == .failed)
        #expect(session.items.last { $0.kind == .assistant }?.text == "README.md has one heading. I didn't push.")
        let result = try #require(reducer.lastResult)
        #expect(!result.isError)
        #expect(result.inputTokens == 9000 + 2000 + 500 + 1000 + 9000)
        #expect(result.outputTokens == 120 + 30 + 50)
        #expect(abs((result.costUSD ?? 0) - 0.02) < 1e-9)
        #expect(result.durationMs == 2600)
    }

    @Test func aFailedExitIsAnError() throws {
        let lines = [#"{"type":"error","timestamp":1,"sessionID":"ses_1","error":{"name":"ProviderAuthError","data":{"message":"No API key for anthropic"}}}"#]
        let (_, reducer) = replay(lines, parser: OpenCodeStreamParser(), agent: .opencode, exitStatus: 1)
        #expect(reducer.lastResult?.isError == true)
        #expect(reducer.lastResult?.text == "No API key for anthropic")
        // Nothing on stdout: the runner reports the exit itself.
        var parser = OpenCodeStreamParser()
        #expect(parser.finish(exitStatus: 1).isEmpty)
    }

    @Test func buildsArguments() {
        var request = AgentRunRequest(prompt: "say \"hi\" to me", workingDirectory: URL(fileURLWithPath: "/repo"),
                                      model: "anthropic/claude-sonnet-5-5", access: .readOnly, resumeSessionID: nil)
        let first = OpenCodeProvider().invocation(for: request)
        #expect(first.arguments.prefix(3) == ["run", "--format", "json"])
        #expect(first.arguments.contains("plan"))
        #expect(first.stdin == "say \"hi\" to me", "on stdin, so it isn't re-quoted")
        request.resumeSessionID = "ses_1"
        request.access = .fullAccess
        let next = OpenCodeProvider().invocation(for: request)
        #expect(next.arguments.contains("--auto") && !next.arguments.contains("plan"))
        #expect(next.arguments.suffix(2) == ["--session", "ses_1"])
        #expect(OpenCodeProvider.parseModels("anthropic/claude-sonnet-5-5\nopenai/gpt-6-luna\n").map(\.id) == [nil, "anthropic/claude-sonnet-5-5", "openai/gpt-6-luna"])
    }
}
