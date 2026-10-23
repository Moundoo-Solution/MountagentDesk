import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct LocalUsageTests {
    @Test func countsEachClaudeMessageOnce() throws {
        let usage = #""usage":{"input_tokens":1000,"cache_creation_input_tokens":2000,"cache_read_input_tokens":1000000,"output_tokens":500,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0},"speed":"standard"}"#
        let line = #"{"type":"assistant","timestamp":"2026-10-20T10:00:00.000Z","cwd":"/work/acme","message":{"id":"msg_1","model":"claude-opus-5-5",\#(usage)}}"#
        // Three blocks of one message, plus another message on a model without a price.
        let other = #"{"type":"assistant","timestamp":"2026-10-20T11:00:00.000Z","cwd":"/work/acme","message":{"id":"msg_2","model":"claude-future-9","usage":{"input_tokens":10,"output_tokens":10}}}"#
        let entries = LocalUsage.claudeEntries([line, line, line, other].joined(separator: "\n"), prices: .builtIn)
        let opus = try #require(entries.first { $0.model == "claude-opus-5-5" })
        #expect(opus.input == 1000 && opus.cacheRead == 1_000_000 && opus.cacheWrite == 2000 && opus.output == 500)
        // 1000×4 + 1,000,000×0.20 + 2000×4×2 (1-hour writes) + 500×20, per million.
        #expect(abs((opus.costUSD ?? 0) - 0.230) < 0.0001)
        #expect(entries.first { $0.model == "claude-future-9" }?.costUSD == nil)
        #expect(opus.folder == "/work/acme")
    }

    @Test func codexCountsTheGrowthOfItsTotals() throws {
        let lines = [
            #"{"timestamp":"2026-10-20T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/work/shop"}}"#,
            #"{"timestamp":"2026-10-20T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-6-luna","cwd":"/work/shop"}}"#,
            #"{"timestamp":"2026-10-20T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":4000,"output_tokens":100},"last_token_usage":{"input_tokens":10000}}}}"#,
            // Repeated with the same totals: nothing new.
            #"{"timestamp":"2026-10-20T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":4000,"output_tokens":100},"last_token_usage":{"input_tokens":10000}}}}"#,
            #"{"timestamp":"2026-10-20T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":30000,"cached_input_tokens":14000,"output_tokens":300},"last_token_usage":{"input_tokens":20000}}}}"#,
        ]
        let entries = LocalUsage.codexEntries(lines.joined(separator: "\n"), prices: .builtIn)
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && entry.model == "gpt-6-luna" && entry.folder == "/work/shop")
        #expect(entry.input == 16000 && entry.cacheRead == 14000 && entry.output == 300)
        #expect(abs((entry.costUSD ?? 0) - (16000 * 0.10 + 14000 * 0.01 + 300 * 0.50) / 1_000_000) < 1e-9)
    }

    @Test func pricesFollowTiersDatesAndOverrides() {
        let prices = ModelPrices.builtIn
        #expect(prices.price(for: "claude-haiku-5-5", promptTokens: 50_000)?.input == 0.10)
        #expect(prices.price(for: "claude-haiku-5-5", promptTokens: 150_000)?.input == 0.50)
        #expect(prices.price(for: "claude-haiku-4-5-20251001")?.output == 5)
        #expect(prices.price(for: "claude-sonnet-4-5") == nil)
        let mine = prices.merging(["claude-sonnet-4-5": .init(input: 3, output: 15, cacheRead: 0.3)])
        #expect(mine.price(for: "claude-sonnet-4-5")?.input == 3)
    }

    @Test func readsOnlyChangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("claude/p")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"type":"assistant","timestamp":"2026-10-20T10:00:00.000Z","cwd":"/w","message":{"id":"a","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
        try (line + "\n").write(to: claude.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        var cache = LocalUsage.Cache()
        let first = LocalUsage.scan(claudeRoot: root.appendingPathComponent("claude"), codexRoot: root.appendingPathComponent("none"), cache: &cache)
        #expect(first.count == 1 && first[0].costUSD == 2)
        let again = LocalUsage.scan(claudeRoot: root.appendingPathComponent("claude"), codexRoot: root.appendingPathComponent("none"), cache: &cache)
        #expect(again == first)
    }

    @Test func addsUpByDayAgentAndFolder() {
        let now = Date()
        let today = UsageLedger.key(now)
        let old = UsageLedger.key(now.addingTimeInterval(-40 * 86400))
        let entries = [
            LocalUsage.Entry(day: today, agent: .claude, model: "a", folder: "/w/shop", input: 100, costUSD: 1),
            LocalUsage.Entry(day: today, agent: .codex, model: "b", folder: "/w/shop.worktrees/x1", input: 50, costUSD: 0.5),
            LocalUsage.Entry(day: today, agent: .codex, model: "c", folder: "/w/shopping", input: 10),
            LocalUsage.Entry(day: old, agent: .claude, model: "a", folder: "/w/shop/sub", input: 1000, costUSD: 10),
        ]
        #expect(LocalUsage.total(of: entries, lastDays: 1).costUSD == 1.5)
        #expect(LocalUsage.total(of: entries, lastDays: 1).unpricedTokens == 10)
        #expect(LocalUsage.total(of: entries, agent: .claude, lastDays: nil).costUSD == 11)
        #expect(LocalUsage.total(of: entries, folder: "/w/shop", lastDays: nil).tokens == 1150)
        #expect(LocalUsage.byModel(entries, lastDays: 30).map(\.model) == ["a", "b", "c"])
    }

    @Test func readsOnlyWhatWasAppended() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func line(_ id: String) -> String {
            #"{"type":"assistant","timestamp":"2026-10-20T10:00:00.000Z","cwd":"/w","message":{"id":""# + id + #"","model":"claude-sonnet-5-5","usage":{"input_tokens":1000000,"output_tokens":0}}}"# + "\n"
        }
        let file = root.appendingPathComponent("s.jsonl")
        // The second line is still being written.
        try (line("a") + #"{"type":"assist"#).write(to: file, atomically: true, encoding: .utf8)
        var cache = LocalUsage.Cache()
        let none = root.appendingPathComponent("none")
        #expect(LocalUsage.scan(claudeRoot: root, codexRoot: none, cache: &cache).first?.costUSD == 2)
        // Rewritten with the first message's next block and a new message: "a" still counts once.
        try (line("a") + line("a") + line("b")).write(to: file, atomically: true, encoding: .utf8)
        #expect(LocalUsage.scan(claudeRoot: root, codexRoot: none, cache: &cache).first?.costUSD == 4)
        // Shorter than before: read again from the start.
        try line("c").write(to: file, atomically: true, encoding: .utf8)
        #expect(LocalUsage.scan(claudeRoot: root, codexRoot: none, cache: &cache).first?.costUSD == 2)
    }
}
