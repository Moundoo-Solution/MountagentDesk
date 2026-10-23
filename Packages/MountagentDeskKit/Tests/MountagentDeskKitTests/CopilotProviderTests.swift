import Foundation
import Testing
@testable import MountagentDeskKit

/// Replays of real `copilot -p … --output-format json` runs (Copilot CLI 1.0.102).
@Suite struct CopilotProviderTests {
    @Test func replaysCommandsAndAPatch() throws {
        let (session, reducer) = replay(try fixtureLines("copilot-edit"), parser: CopilotStreamParser(), agent: .copilot)
        #expect(session.agentSessionIDs[.copilot] == "8d47675b-f1ba-4779-89d7-5f5a740988cd")

        let tools = session.items.filter { $0.kind == .tool }
        #expect(tools.map(\.toolName) == ["Shell", "Shell", "Edit"])
        #expect(tools.map(\.text) == ["cat hello.txt", "ls", "hello.txt"])
        #expect(tools.allSatisfy { $0.toolStatus == .succeeded })
        let ls = try #require(tools.first { $0.text == "ls" })
        #expect(ls.toolOutput == "err.txt\nhello.txt\nout.jsonl", "the <shellId> trailer is dropped")
        #expect(tools.last?.toolOutput == "edit /tmp/copilot-fixture/hello.txt")

        #expect(session.items.contains { $0.kind == .thinking })
        let texts = session.items.filter { $0.kind == .assistant }.map(\.text)
        #expect(texts == ["Read `hello.txt`, ran `ls`, and appended `bye` to `hello.txt`."])
        #expect(reducer.lastResult?.isError == false)
        #expect(reducer.lastResult?.durationMs == 11772)
    }

    @Test func aDenyRuleIsFinal() throws {
        let (session, _) = replay(try fixtureLines("copilot-denied-rule"), parser: CopilotStreamParser(), agent: .copilot)
        let ssh = try #require(session.items.first { $0.kind == .tool && $0.text == "ssh -V" })
        #expect(ssh.toolStatus == .failed)
        #expect(ssh.toolOutput?.contains("shell(ssh:*)") == true)
        #expect(!session.items.contains { $0.permissionState == .blocked }, "a deny rule offers no retry")
        let created = try #require(session.items.first { $0.toolName == "Edit" })
        #expect(created.toolOutput == "create /tmp/copilot-fixture/new.txt")
        #expect(session.items.contains { $0.toolName == "Read" && $0.text == "/tmp/copilot-fixture/hello.txt" })
    }

    @Test func aCommandNobodyApprovedCanBeRetried() throws {
        let (session, _) = replay(try fixtureLines("copilot-blocked"), parser: CopilotStreamParser(), agent: .copilot)
        #expect(session.items.contains { $0.permissionState == .blocked && $0.toolName == "Shell" })
        #expect(session.items.filter { $0.kind == .tool && $0.toolStatus == .succeeded }.count >= 3)
    }

    @Test func buildsTheCommandLine() {
        var request = AgentRunRequest(prompt: "-fix it", workingDirectory: URL(fileURLWithPath: "/tmp/p"),
                                      additionalDirectories: [URL(fileURLWithPath: "/tmp/q")], model: "gpt-6-luna",
                                      effort: "high", access: .editFiles, resumeSessionID: "abc")
        request.linksServers = true
        request.readsServers = true
        request.images = [URL(fileURLWithPath: "/tmp/shot.png")]
        let args = CopilotProvider().invocation(for: request).arguments
        #expect(args.starts(with: ["--output-format", "json", "--stream", "on", "--no-ask-user"]))
        #expect(args.contains("--allow-tool=write") && !args.contains("--allow-all"))
        #expect(args.contains("--deny-tool=shell(ssh:*)") && args.contains("--allow-tool=shell(mountagent-server:*)"))
        for pair in [["--model", "gpt-6-luna"], ["--reasoning-effort", "high"], ["--add-dir", "/tmp/q"], ["--attachment", "/tmp/shot.png"], ["--resume", "abc"]] {
            #expect(args.contains(pair[0]) && args[args.firstIndex(of: pair[0])! + 1] == pair[1], "\(pair)")
        }
        #expect(args.suffix(2) == ["-p", " -fix it"], "a leading dash isn't read as an option")
        request.access = .fullAccess
        #expect(CopilotProvider().invocation(for: request).arguments.contains("--allow-all"))
        request.access = .readOnly
        #expect(CopilotProvider().invocation(for: request).arguments.contains("--deny-tool=write"))
    }

    @Test func readsModelsAndVersion() {
        let help = """
          `model`: AI model to use for Copilot CLI; can be changed with /model command or --model flag option.
            - "claude-sonnet-5.5"
            - "gpt-6-luna"
            - "gemini-3.8-flash"

          `contextTier`: context window tier
        """
        #expect(CopilotProvider.parseModels(help) == [
            AgentModel(id: nil, name: "Auto"),
            AgentModel(id: "claude-sonnet-5.5", name: "Claude Sonnet 5.5"),
            AgentModel(id: "gpt-6-luna", name: "GPT-6 Luna"),
            AgentModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        ])
        #expect(CopilotProvider.parseVersion("GitHub Copilot CLI 1.0.102.\nRun 'copilot update'") == "1.0.102")
    }
}
