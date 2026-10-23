import Foundation
import Testing
@testable import MountagentDeskKit

/// Talks to the real CLIs, so it needs them installed and signed in, and it spends a few
/// cents. Run with: MOUNTAGENT_LIVE=1 swift test --filter LiveAgentTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MOUNTAGENT_LIVE"] == "1"), .serialized)
struct LiveAgentTests {
    let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskLive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? "pineapple\n".write(to: url.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        return url
    }()

    private func turn(_ text: String, agent: AgentKind, model: String?, session: inout ChatSession, environment: [String: String] = [:]) async throws -> TurnResult? {
        let missed = session.unseenItems(for: agent)
        session.agent = agent
        session.items.append(ChatItem(kind: .user, text: text))
        let request = AgentRunRequest(
            prompt: PromptBuilder.prompt(text, attachments: [], missed: missed),
            workingDirectory: directory,
            model: model,
            access: .editFiles,
            resumeSessionID: session.agentSessionIDs[agent]
        )
        var withEnvironment = request
        withEnvironment.environment = environment
        let run = try AgentRunner().start(withEnvironment, with: AgentProviders.provider(for: agent))
        var reducer = TranscriptReducer(agent: agent)
        for await event in run.events {
            reducer.apply(event, to: &session)
        }
        session.seenCounts[agent] = session.items.count
        return reducer.lastResult
    }

    @Test func claudeThenCursorSharesTheConversation() async throws {
        var session = ChatSession(projectID: UUID(), agent: .claude)

        let first = try await turn("Read secret.txt and reply with only the word in it.", agent: .claude, model: "haiku", session: &session)
        #expect(first?.isError == false)
        #expect(session.items.contains { $0.kind == .tool && $0.toolStatus == .succeeded })
        #expect(session.items.last { $0.kind == .assistant }?.text.lowercased().contains("pineapple") == true)

        // Cursor never saw that turn; the handoff must carry it.
        let second = try await turn("What word did the file contain? Reply with only that word, without reading any file.", agent: .cursor, model: nil, session: &session)
        #expect(second?.isError == false)
        #expect(session.items.last { $0.kind == .assistant }?.text.lowercased().contains("pineapple") == true)

        // Claude resumes its own CLI session.
        let third = try await turn("Reply with the number 7 and nothing else.", agent: .claude, model: "haiku", session: &session)
        #expect(third?.isError == false)
        #expect(session.agentSessionIDs.count == 2)
    }

    @Test func copilotAccountIsSignedIn() throws {
        let login = try #require(ProcessInfo.processInfo.environment["MOUNTAGENT_COPILOT_LOGIN"])
        let account = AccountProbe(runner: AgentRunner(), copilotLogin: login).probe(.copilot)
        #expect(account.isInstalled)
        #expect(account.version != nil)
        #expect(account.loggedIn)
        #expect(account.email == login)
    }

    /// Signs in as `MOUNTAGENT_COPILOT_LOGIN`'s gh account, else Copilot's own sign-in.
    @Test func copilotReadsAndResumes() async throws {
        var environment: [String: String] = [:]
        if let login = ProcessInfo.processInfo.environment["MOUNTAGENT_COPILOT_LOGIN"], let token = GitHubCLI.token(for: login) {
            environment[CopilotProvider.tokenVariable] = token
        }
        var session = ChatSession(projectID: UUID(), agent: .copilot)
        let first = try await turn("Read secret.txt and reply with only the word in it.", agent: .copilot, model: nil, session: &session, environment: environment)
        #expect(first?.isError == false)
        #expect(session.items.contains { $0.kind == .tool && $0.toolStatus == .succeeded })
        #expect(session.items.last { $0.kind == .assistant }?.text.lowercased().contains("pineapple") == true)
        #expect(session.agentSessionIDs[.copilot] != nil)

        let second = try await turn("Reply with the number 7 and nothing else.", agent: .copilot, model: nil, session: &session, environment: environment)
        #expect(second?.isError == false)
        #expect(session.items.last { $0.kind == .assistant }?.text.contains("7") == true)
    }

    @Test func codexReadsAndResumes() async throws {
        var session = ChatSession(projectID: UUID(), agent: .codex)
        let first = try await turn("Read secret.txt and reply with only the word in it.", agent: .codex, model: nil, session: &session)
        #expect(first?.isError == false)
        #expect(session.items.last { $0.kind == .assistant }?.text.lowercased().contains("pineapple") == true)
        #expect(session.agentSessionIDs[.codex] != nil)

        // The second turn resumes Codex's own thread.
        let second = try await turn("What word was it? Reply with only that word, without reading any file.", agent: .codex, model: nil, session: &session)
        #expect(second?.isError == false)
        #expect(session.items.last { $0.kind == .assistant }?.text.lowercased().contains("pineapple") == true)
    }

    /// Signed in, Antigravity answers; signed out, it would wait for a pasted code: either
    /// way the turn has to end.
    @Test(.timeLimit(.minutes(3))) func antigravityAnswersOrAsksToSignIn() async throws {
        var session = ChatSession(projectID: UUID(), agent: .antigravity)
        _ = try await turn("Read secret.txt and reply with only the word in it.", agent: .antigravity, model: nil, session: &session)
        let notice = session.items.last { $0.kind == .notice }?.text ?? ""
        let answer = session.items.last { $0.kind == .assistant }?.text.lowercased() ?? ""
        #expect(answer.contains("pineapple") || notice.contains("sign in again"), "got: \(notice)")
    }

    @Test(arguments: [PermissionReply.allow, .deny])
    func claudeWaitsForPermission(_ reply: PermissionReply) async throws {
        let request = AgentRunRequest(
            prompt: #"Use the Bash tool to run exactly: python3 -c "print(6*7)". Then reply with the number, or say DECLINED if you could not run it."#,
            workingDirectory: directory, model: "haiku", access: .editFiles, resumeSessionID: nil
        )
        let run = try AgentRunner().start(request, with: ClaudeProvider())
        var reducer = TranscriptReducer(agent: .claude)
        var session = ChatSession(projectID: UUID(), agent: .claude)
        var asked = 0
        for await event in run.events {
            if case .permissionRequest(let permission) = event {
                asked += 1
                #expect(run.respond(reply, to: permission))
            }
            reducer.apply(event, to: &session)
        }
        #expect(asked >= 1)
        #expect(reducer.lastResult?.isError == false)
        let answer = session.items.last { $0.kind == .assistant }?.text ?? ""
        let tool = session.items.first { $0.kind == .tool && $0.toolName == "Bash" }
        if reply == .allow {
            #expect(answer.contains("42"))
            #expect(tool?.toolStatus == .succeeded)
        } else {
            #expect(!answer.contains("42"))
            #expect(tool?.toolStatus == .failed)
        }
    }

    @Test func cancelStopsTheRun() async throws {
        let request = AgentRunRequest(prompt: "Count slowly from 1 to 500, one number per line.", workingDirectory: directory, model: "haiku", access: .readOnly, resumeSessionID: nil)
        let run = try AgentRunner().start(request, with: ClaudeProvider())
        Task {
            try? await Task.sleep(for: .seconds(4))
            run.cancel()
        }
        var events: [AgentEvent] = []
        for await event in run.events { events.append(event) }
        #expect(events.last == .failure("Stopped."))
    }
}
