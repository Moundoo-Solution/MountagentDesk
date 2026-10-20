import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct AccountTests {
    @Test func readsClaudeAuthStatus() {
        var account = AgentAccount(kind: .claude)
        AccountProbe.applyClaudeStatus(#"""
        {"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "orgName": "Acme", "subscriptionType": "team"}
        """#, to: &account)
        #expect(account.loggedIn)
        #expect(account.email == "me@example.com")
        #expect(account.organization == "Acme")
        #expect(account.plan == "Team")

        var loggedOut = AgentAccount(kind: .claude)
        AccountProbe.applyClaudeStatus(#"{"loggedIn": false}"#, to: &loggedOut)
        #expect(!loggedOut.loggedIn)
    }

    @Test func readsCursorAbout() {
        var account = AgentAccount(kind: .cursor)
        AccountProbe.applyCursorAbout("""
        Checking…
        {"cliVersion": "2026.10.18-ea085cb", "latestStatus": "update_available", "latestVersion": "2026.10.19-6bbf2c4", "subscriptionTier": "Pro", "userEmail": "me@example.com"}
        """, to: &account)
        #expect(account.version == "2026.10.18-ea085cb")
        #expect(account.updateAvailable)
        #expect(account.plan == "Pro")
        #expect(account.email == "me@example.com")
    }

    @Test func parsesClaudeRateLimits() throws {
        var parser = ClaudeStreamParser()
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.43,"resetsAt":1792431600},"seven_day":{"utilization":0.33,"resetsAt":1792825200}}}}"#
        guard case .rateLimit(let info) = try #require(parser.parse(line: line).first) else {
            Issue.record("expected rate limit")
            return
        }
        #expect(info.windows.map(\.name) == ["five_hour", "seven_day"])
        #expect(info.windows.first?.utilization == 0.43)
        #expect(info.windows.first?.resetsAt == Date(timeIntervalSince1970: 1792431600))
        #expect(RateLimitInfo.title(of: "seven_day") == "Weekly limit")
    }

    @Test func totalsUsageByDay() {
        var ledger = UsageLedger()
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let old = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        ledger.record(TurnResult(isError: false, costUSD: 0.5, inputTokens: 100, outputTokens: 20), agent: .claude, on: now)
        ledger.record(TurnResult(isError: false, costUSD: 0.25, inputTokens: 50, outputTokens: 5), agent: .claude, on: yesterday)
        ledger.record(TurnResult(isError: false, costUSD: 9, inputTokens: 9, outputTokens: 9), agent: .claude, on: old)
        ledger.record(TurnResult(isError: false, inputTokens: 70, outputTokens: 7), agent: .cursor, on: now)

        let today = ledger.total(for: .claude, lastDays: 1, now: now)
        #expect(today.turns == 1 && today.totalTokens == 120 && today.costUSD == 0.5)
        let week = ledger.total(for: .claude, lastDays: 7, now: now)
        #expect(week.turns == 2 && week.costUSD == 0.75)
        let cursor = ledger.total(for: .cursor, lastDays: 7, now: now)
        #expect(cursor.totalTokens == 77 && !cursor.hasCost)

        let data = try! JSONEncoder().encode(ledger)
        #expect(try! JSONDecoder().decode(UsageLedger.self, from: data) == ledger)
    }

    @Test func buildsSetupCommands() {
        #expect(AgentSetup.loginCommand(for: .claude, executable: "/Users/a b/.local/bin/claude") == "'/Users/a b/.local/bin/claude' auth login")
        #expect(AgentSetup.loginCommand(for: .cursor, executable: nil) == "cursor-agent login")
        #expect(AgentSetup.installCommand(for: .cursor).contains("cursor.com/install"))
    }
}

@Suite struct PlanUsageTests {
    @Test func parsesUsageReport() throws {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 55% used · resets Oct 20 at 11:49am (Asia/Saigon)
        Current week (all models): 46% used · resets Oct 24 at 1:59pm (Asia/Saigon)

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine.

        Last 24h · 726 requests · 42 sessions
          86% of your usage was at >150k context
        """
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 20; components.hour = 9
        let now = try #require(Calendar.current.date(from: components))
        let usage = try #require(PlanUsage.parse(text, now: now))
        #expect(usage.limits.map(\.name) == ["Session (5hr)", "Weekly (all models)"])
        #expect(usage.limits.map(\.percent) == [55, 46])
        #expect(usage.limits[0].resetText == "Oct 20 at 11:49am")
        let reset = try #require(usage.limits[0].resetsAt)
        #expect(Calendar.current.dateComponents([.month, .day, .hour, .minute], from: reset) == DateComponents(month: 10, day: 20, hour: 11, minute: 49))
        #expect(usage.notes == ["Last 24h · 726 requests · 42 sessions", "86% of your usage was at >150k context"])
        #expect(PlanUsage.parse("Not logged in") == nil)
    }

    @Test func takesFresherPercentagesFromTurns() {
        let usage = PlanUsage(limits: [
            .init(name: "Session (5hr)", percent: 55, resetsAt: nil, resetText: "Oct 20 at 11:49am"),
            .init(name: "Weekly (all models)", percent: 46, resetsAt: nil, resetText: nil),
        ], notes: ["Last 24h"])
        let info = RateLimitInfo(windows: [
            .init(name: "five_hour", utilization: 0.61, resetsAt: Date(timeIntervalSince1970: 1)),
            .init(name: "seven_day", utilization: 0.475, resetsAt: nil),
        ])
        let updated = usage.updated(with: info)
        #expect(updated.limits.map(\.percent) == [61, 48])
        #expect(updated.limits[0].resetsAt == Date(timeIntervalSince1970: 1))
        #expect(updated.notes == ["Last 24h"])
    }
}

@Suite struct CursorUsageTests {
    @Test func readsTheIDEsFields() throws {
        let json = #"""
        {"billingCycleStart":"1790000000000","billingCycleEnd":"1792627200000",
         "planUsage":{"totalSpend":1530,"includedSpend":1360,"bonusSpend":0,"limit":2000,"autoPercentUsed":21.4,"apiPercentUsed":47.6,"totalPercentUsed":68},
         "spendLimitUsage":{"individualUsed":500,"individualLimit":2000},
         "displayMessage":"You've used 68% of your included usage"}
        """#
        let usage = try #require(CursorUsage.parse(Data(json.utf8)))
        #expect(usage.usedPercent == 68)
        #expect(usage.usedUSD == 13.6 && usage.limitUSD == 20)
        #expect(usage.cycleEnd == Date(timeIntervalSince1970: 1792627200))
        #expect(usage.limits.map(\.name) == ["Included usage", "Auto", "Named models", "Spend limit"])
        #expect(usage.limits.map(\.percent) == [68, 21, 48, 25])
        #expect(usage.message?.hasPrefix("You've used") == true)
    }

    @Test func fallsBackToTotalPercentWithoutALimit() throws {
        let usage = try #require(CursorUsage.parse(Data(#"{"planUsage":{"includedSpend":0,"limit":0,"totalPercentUsed":12.5}}"#.utf8)))
        #expect(usage.usedPercent == 12.5)
        #expect(usage.limits.count == 1)
        #expect(CursorUsage.parse(Data("{}".utf8)) == nil)
        #expect(CursorUsage.parse(Data("not json".utf8)) == nil)
    }
}
