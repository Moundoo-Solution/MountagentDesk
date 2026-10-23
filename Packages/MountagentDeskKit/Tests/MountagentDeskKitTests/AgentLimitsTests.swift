import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct AgentLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func readsCodexLimitsFromItsSessionLog() throws {
        let line = #"{"timestamp":"2026-09-21T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":42.4,"window_minutes":300,"resets_at":1790003600},"secondary":{"used_percent":7.0,"window_minutes":10080,"resets_at":1789000000},"plan_type":"plus"}}}"#
        let usage = try #require(CodexLimits.parse(line, now: now))
        #expect(usage.limits.map(\.name) == ["5-hour limit", "Weekly limit"])
        #expect(usage.limits.map(\.percent) == [42, 0], "a window that has reset starts from nothing")
        #expect(usage.limits[0].resetsAt == Date(timeIntervalSince1970: 1_790_003_600))
        #expect(usage.notes == ["Plus"])
        #expect(CodexLimits.parse(#"{"payload":{"rate_limits":{"primary":null}}}"#, now: now) == nil)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("sessions/2026/09/21")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try ("{\"type\":\"session_meta\"}\n" + line + "\n{\"type\":\"other\"}\n").write(to: folder.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        #expect(CodexLimits.latest(home: home, now: now)?.limits.first?.percent == 42)
    }

    @Test func readsTheCodexAccountFromTheIdentityToken() throws {
        let claims = #"{"email":"alex@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
        let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let account = CodexLimits.claims(ofJWT: "eyJhbGciOiJub25lIn0.\(payload).sig")
        #expect(account.email == "alex@example.com" && account.plan == "Pro")
        #expect(CodexLimits.claims(ofJWT: "nonsense").email == nil)
    }

    @Test func readsCopilotQuotas() throws {
        let json = #"{"copilot_plan":"individual","access_type_sku":"free_limited_copilot","quota_reset_date":"2026-11-01","quota_snapshots":{"chat":{"entitlement":50,"percent_remaining":98.8,"unlimited":false},"completions":{"unlimited":true},"premium_interactions":{"entitlement":0,"percent_remaining":0,"unlimited":false}}}"#
        let result = try #require(CopilotLimits.parse(Data(json.utf8), now: now))
        #expect(result.plan == "Free")
        #expect(result.usage.limits.map(\.name) == ["Chat"] && result.usage.limits[0].percent == 1)
        #expect(result.usage.notes == ["No premium requests in this plan"])
        #expect(result.usage.limits[0].resetsAt != nil)
        let pro = #"{"copilot_plan":"individual","quota_reset_date":"2026-11-01","quota_snapshots":{"chat":{"unlimited":true},"premium_interactions":{"entitlement":300,"percent_remaining":60,"unlimited":false}}}"#
        let paid = try #require(CopilotLimits.parse(Data(pro.utf8), now: now))
        #expect(paid.plan == "Pro" && paid.usage.limits.map(\.percent) == [40])
    }
}

@Suite struct SessionActivityTests {
    @Test func saysWhatTheAgentIsDoing() {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        #expect(SessionActivity.line(for: session, running: false) == nil)
        session.items = [ChatItem(kind: .user, text: "go")]
        #expect(SessionActivity.line(for: session, running: true)?.text == "Starting…")
        session.items.append(ChatItem(kind: .tool, agent: .claude, text: "python3 -m unittest", toolName: "Bash", toolStatus: .running))
        #expect(SessionActivity.line(for: session, running: true) == .init(state: .working, text: "Running python3 -m unittest"))
        session.items.append(ChatItem(kind: .permission, agent: .claude, text: "rm -rf build", toolName: "Bash", permissionState: .pending))
        #expect(SessionActivity.line(for: session, running: true) == .init(state: .waiting, text: "Needs you: run rm -rf build"))
        session.items[2].permissionState = .allowed
        session.items.append(ChatItem(kind: .assistant, agent: .claude, text: "## Done\n\n**All 8 tests** pass.\nMountagent-Title: x"))
        #expect(SessionActivity.line(for: session, running: false) == .init(state: .finished, text: "Done"))
        session.items.append(ChatItem(kind: .notice, text: "Claude stopped: not signed in", isError: true))
        #expect(SessionActivity.line(for: session, running: false)?.state == .failed)
    }
}

@Suite struct TerminalSessionTests {
    @Test func namesAndOffersCommands() {
        #expect(TerminalCommands.title(for: "aider --model sonnet") == "aider")
        #expect(TerminalCommands.title(for: "DEBUG=1 /opt/homebrew/bin/htop") == "htop")
        #expect(TerminalCommands.title(for: "  ") == "Shell")
        #expect(TerminalCommands.title(for: "kiro-cli chat") == "Kiro")
        #expect(TerminalCommands.installed { $0 == "aider" || $0 == "claude" ? URL(fileURLWithPath: "/bin/\($0)") : nil } == ["claude", "aider"])
        #expect(TerminalCommands.title(for: "droid") == "Droid")
        #expect(TerminalCommands.agents.map(\.name) == ["Kiro", "Amp", "Kimi Code", "Grok Build", "Mistral Vibe", "Droid"])
    }

    @Test func runsKiroThroughItsOwnInterface() {
        let installed: (String) -> URL? = { URL(fileURLWithPath: "/bin/\($0)") }
        #expect(TerminalCommands.line(for: "kiro-cli chat", hasRun: false, find: installed) == "kiro-cli chat")
        #expect(TerminalCommands.line(for: "kiro-cli chat", hasRun: true, find: installed) == "kiro-cli chat --resume")
        #expect(TerminalCommands.line(for: "kiro-cli chat", hasRun: false) { _ in nil } == "curl -fsSL https://cli.kiro.dev/install | bash && kiro-cli chat")
        #expect(TerminalCommands.line(for: "kiro-cli chat --agent mine", hasRun: true, find: installed) == "kiro-cli chat --agent mine", "the user's own line runs as typed")
        #expect(TerminalCommands.line(for: "droid", hasRun: true, find: installed) == "droid --resume --last")
        #expect(TerminalCommands.line(for: "amp", hasRun: true, find: installed) == "amp", "started bare again")
        var session = ChatSession(projectID: UUID(), agent: .claude)
        session.command = "kiro-cli chat"
        #expect(SessionActivity.line(for: session, running: false)?.text == "Kiro in the terminal")
    }

    @Test func savesTheCommandAndShowsIt() throws {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        #expect(!session.isTerminal)
        session.command = "aider --yes"
        session.commandHasRun = true
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.command == "aider --yes" && decoded.commandHasRun)
        #expect(SessionActivity.line(for: decoded, running: false)?.text == "$ aider --yes")
        session.command = ""
        #expect(SessionActivity.line(for: session, running: false)?.text == "Shell")
    }
}
