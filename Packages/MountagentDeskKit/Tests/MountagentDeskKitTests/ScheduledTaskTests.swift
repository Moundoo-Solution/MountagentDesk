import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ScheduledTaskTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(_ text: String) -> Date { try! Date(text + "Z", strategy: .iso8601) }

    func task(_ repeats: ScheduledTask.Repeat) -> ScheduledTask {
        ScheduledTask(name: "Check", projectID: UUID(), agent: .claude, prompt: "Run the tests", repeats: repeats, hour: 9, minute: 30, weekday: 4, everyHours: 3)
    }

    @Test func findsTheNextRun() {
        // 2026-10-23 is a Friday.
        #expect(task(.daily).nextRun(after: date("2026-10-23T08:00:00"), calendar: calendar) == date("2026-10-23T09:30:00"))
        #expect(task(.daily).nextRun(after: date("2026-10-23T09:30:00"), calendar: calendar) == date("2026-10-24T09:30:00"))
        #expect(task(.weekdays).nextRun(after: date("2026-10-23T10:00:00"), calendar: calendar) == date("2026-10-26T09:30:00"), "skips the weekend")
        #expect(task(.weekly).nextRun(after: date("2026-10-23T10:00:00"), calendar: calendar) == date("2026-10-28T09:30:00"), "the next Wednesday")
        #expect(task(.hourly).nextRun(after: date("2026-10-23T10:00:00"), calendar: calendar) == date("2026-10-23T13:00:00"))
    }

    @Test func isDueOnceAfterAMissedRun() {
        var check = task(.daily)
        check.createdAt = date("2026-10-20T12:00:00")
        check.lastRun = date("2026-10-21T09:30:00")
        // Closed for two days: due now, and once run, not again until tomorrow.
        let now = date("2026-10-23T15:00:00")
        #expect(check.isDue(at: now, calendar: calendar))
        check.lastRun = now
        #expect(!check.isDue(at: now, calendar: calendar))
        #expect(check.nextRun(calendar: calendar) == date("2026-10-24T09:30:00"))
        check.enabled = false
        #expect(!check.isDue(at: date("2026-10-30T15:00:00"), calendar: calendar))
    }

    @Test func describesTheSchedule() {
        #expect(task(.weekdays).scheduleDescription(calendar: calendar) == "Mon–Fri at 09:30")
        #expect(task(.weekly).scheduleDescription(calendar: calendar) == "Every Wednesday at 09:30")
        #expect(task(.hourly).scheduleDescription(calendar: calendar) == "Every 3 hours")
    }
}
