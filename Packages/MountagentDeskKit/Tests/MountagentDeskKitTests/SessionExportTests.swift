import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct SessionExportTests {
    @Test func writesTheConversation() {
        var session = ChatSession(projectID: UUID(), title: "Sửa lỗi báo giá", agent: .claude)
        session.items = [
            ChatItem(kind: .user, text: "Fix the quote total"),
            ChatItem(kind: .thinking, agent: .claude, text: "secret thoughts"),
            ChatItem(kind: .tool, agent: .claude, text: "grep -n total", toolName: "Bash", toolOutput: "a ``` b", toolStatus: .succeeded),
            ChatItem(kind: .assistant, agent: .claude, text: "Fixed.\nMountagent-Title: Quote total"),
            ChatItem(kind: .notice, text: "Stopped", isError: true),
        ]
        let text = SessionExport.markdown(session, projectName: "Acme")
        #expect(text.hasPrefix("# Sửa lỗi báo giá\n"))
        #expect(text.contains("**You:**\n\nFix the quote total"))
        #expect(text.contains("**\(AgentKind.claude.displayName):**\n\nFixed.") && !text.contains("Mountagent-Title"))
        #expect(!text.contains("secret thoughts"))
        #expect(text.contains("- `Bash` grep -n total") && text.contains("  ````\n  a ``` b\n  ````"))
        #expect(text.contains("> ⚠️ Stopped"))
        #expect(SessionExport.fileName(for: session) == "Sua-loi-bao-gia.md")
    }

    @Test func archivedSurvivesSaving() throws {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        session.archived = true
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONEncoder().encode(session))
        #expect(decoded.archived)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        json.removeValue(forKey: "archived")
        #expect(try !JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: json)).archived)
    }

    @Test func countsUsagePerProject() throws {
        var ledger = UsageLedger()
        let project = UUID()
        ledger.record(TurnResult(isError: false, costUSD: 0.5, inputTokens: 100, outputTokens: 20), agent: .claude, project: project)
        ledger.record(TurnResult(isError: false, inputTokens: 10, outputTokens: 5), agent: .codex, project: project)
        ledger.record(TurnResult(isError: false, costUSD: 1), agent: .claude)
        let total = ledger.total(forProject: project, lastDays: 1)
        #expect(total.turns == 2 && total.totalTokens == 135 && total.costUSD == 0.5)
        #expect(ledger.total(for: .claude, lastDays: 1).costUSD == 1.5)
        let csv = ledger.projectCSV(names: [project: "Acme \"UAT\""])
        #expect(csv.contains(",\"Acme \"\"UAT\"\"\",2,110,25,0.5000"))
        let old = try JSONDecoder().decode(UsageLedger.self, from: Data(#"{"days":{}}"#.utf8))
        #expect(old.projects.isEmpty)
    }
}

@Suite struct SessionSearchTests {
    @Test func findsByTitleProjectAndText() {
        let acme = UUID()
        var quote = ChatSession(projectID: acme, title: "Quote total fix", agent: .claude)
        quote.updatedAt = .now
        var report = ChatSession(projectID: acme, title: "Invoice report", agent: .codex)
        report.items = [ChatItem(kind: .assistant, text: "The PDF layout now shows the quote number at the top of each page.")]
        report.updatedAt = .now.addingTimeInterval(-60)
        var old = ChatSession(projectID: UUID(), title: "Unrelated", agent: .cursor)
        old.archived = true
        let names = [acme: "Acme"]
        let found = SessionSearch.results(for: "quote", in: [report, old, quote], projects: names)
        #expect(found.map(\.title) == ["Quote total fix", "Invoice report"])
        #expect(found.last?.snippet?.contains("quote number") == true)
        #expect(SessionSearch.results(for: "acme invoice", in: [report, old, quote], projects: names).map(\.title) == ["Invoice report"])
        #expect(SessionSearch.results(for: "", in: [report, old, quote], projects: names).count == 3)
        #expect(SessionSearch.results(for: "nothing here", in: [report], projects: names).isEmpty)
    }
}

@Suite struct PromptTemplateTests {
    @Test func matchesSlashCommands() {
        let templates = PromptTemplate.defaults
        #expect(PromptTemplate.matches(for: "/", in: templates)?.count == templates.count)
        #expect(PromptTemplate.matches(for: "/commit message", in: templates)?.map(\.title) == ["Write a commit message"])
        #expect(PromptTemplate.matches(for: "/add test", in: templates)?.map(\.title) == ["Add tests for the change"])
        #expect(!templates.contains { $0.text.localizedCaseInsensitiveContains("odoo") || $0.text.contains("migrat") })
        #expect(PromptTemplate.matches(for: "fix /this", in: templates) == nil)
        #expect(PromptTemplate.matches(for: "/a\nb", in: templates) == nil)
    }
}
