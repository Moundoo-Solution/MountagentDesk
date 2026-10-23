import Foundation

/// A prompt an agent runs on its own at set times, each run in a new session of its
/// project. Runs happen while Mountagent Desk is open; one missed while it was closed runs
/// once when it opens again.
public struct ScheduledTask: Codable, Identifiable, Hashable, Sendable {
    public enum Repeat: String, Codable, CaseIterable, Identifiable, Sendable {
        case daily, weekdays, weekly, hourly

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .daily: "Every day"
            case .weekdays: "Monday to Friday"
            case .weekly: "Every week"
            case .hourly: "Every few hours"
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var projectID: UUID
    public var agent: AgentKind
    public var prompt: String
    public var access: AccessLevel
    /// Each run in a worktree of its own, so it doesn't touch the main folder's files.
    public var inWorktree = false
    public var repeats: Repeat
    /// Time of day, for daily, weekday and weekly runs.
    public var hour: Int
    public var minute: Int
    /// 1 Sunday … 7 Saturday (Calendar's numbering), for weekly runs.
    public var weekday: Int
    /// For hourly runs.
    public var everyHours: Int
    public var enabled = true
    public var createdAt: Date
    public var lastRun: Date?
    public var lastSessionID: UUID?

    public init(name: String, projectID: UUID, agent: AgentKind, prompt: String, access: AccessLevel = .readOnly,
                repeats: Repeat = .weekdays, hour: Int = 9, minute: Int = 0, weekday: Int = 2, everyHours: Int = 4, createdAt: Date = .now) {
        self.name = name
        self.projectID = projectID
        self.agent = agent
        self.prompt = prompt
        self.access = access
        self.repeats = repeats
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.everyHours = everyHours
        self.createdAt = createdAt
    }

    /// The first time after `date` the task is due.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        switch repeats {
        case .hourly:
            return date.addingTimeInterval(TimeInterval(max(1, everyHours) * 3600))
        case .daily:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) ?? date.addingTimeInterval(86400)
        case .weekly:
            return calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: minute, weekday: weekday), matchingPolicy: .nextTime) ?? date.addingTimeInterval(7 * 86400)
        case .weekdays:
            var candidate = date
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: candidate, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime) else { break }
                if !calendar.isDateInWeekend(next) { return next }
                candidate = next
            }
            return date.addingTimeInterval(86400)
        }
    }

    /// The next run from the last one (or from when the task was made).
    public func nextRun(calendar: Calendar = .current) -> Date {
        nextRun(after: lastRun ?? createdAt, calendar: calendar)
    }

    public func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        enabled && nextRun(calendar: calendar) <= now
    }

    /// In the app's language, whatever the Mac's: Sunday first, as `weekday` counts.
    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "Mon–Fri at 09:00", "Every 4 hours".
    public func scheduleDescription(calendar: Calendar = .current) -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch repeats {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Mon–Fri at \(time)"
        case .weekly:
            let day = Self.weekdayNames.indices.contains(weekday - 1) ? Self.weekdayNames[weekday - 1] : "week"
            return "Every \(day) at \(time)"
        case .hourly: return everyHours == 1 ? "Every hour" : "Every \(everyHours) hours"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        prompt = try container.decode(String.self, forKey: .prompt)
        access = try container.decodeIfPresent(AccessLevel.self, forKey: .access) ?? .readOnly
        inWorktree = try container.decodeIfPresent(Bool.self, forKey: .inWorktree) ?? false
        repeats = try container.decodeIfPresent(Repeat.self, forKey: .repeats) ?? .daily
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekday = try container.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        everyHours = try container.decodeIfPresent(Int.self, forKey: .everyHours) ?? 4
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastRun = try container.decodeIfPresent(Date.self, forKey: .lastRun)
        lastSessionID = try container.decodeIfPresent(UUID.self, forKey: .lastSessionID)
    }
}
