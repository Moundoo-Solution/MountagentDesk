import Foundation

/// Cursor's usage for the current billing cycle, from the same endpoint Cursor's IDE uses
/// (`aiserver.v1.DashboardService/GetCurrentPeriodUsage`). It is not a public API, so every
/// field is optional and a failure only hides the meters.
public struct CursorUsage: Codable, Equatable, Sendable {
    /// Share of the plan's included usage spent, 0–100.
    public var usedPercent: Double?
    public var autoPercent: Double?
    public var apiPercent: Double?
    public var usedUSD: Double?
    public var limitUSD: Double?
    public var spendUsedUSD: Double?
    public var spendLimitUSD: Double?
    public var cycleEnd: Date?
    public var message: String?
    public var fetchedAt: Date

    /// Reads the Connect JSON response, mirroring the IDE's arithmetic: amounts are in
    /// cents, and the included percentage is spend over limit when there is a limit.
    public static func parse(_ data: Data, now: Date = .now) -> CursorUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var usage = CursorUsage(fetchedAt: now)
        if let plan = object["planUsage"] as? [String: Any] {
            let included = number(plan["includedSpend"])
            let limit = number(plan["limit"])
            usage.usedUSD = included.map { $0 / 100 }
            usage.limitUSD = limit.map { $0 / 100 }
            if let included, let limit, limit > 0 {
                usage.usedPercent = min(included / limit * 100, 100)
            } else {
                usage.usedPercent = number(plan["totalPercentUsed"])
            }
            usage.autoPercent = number(plan["autoPercentUsed"])
            usage.apiPercent = number(plan["apiPercentUsed"])
        }
        if let spend = object["spendLimitUsage"] as? [String: Any] {
            usage.spendUsedUSD = number(spend["individualUsed"]).map { $0 / 100 }
            usage.spendLimitUSD = number(spend["individualLimit"]).map { $0 / 100 }
        }
        if let end = number(object["billingCycleEnd"]), end > 0 {
            usage.cycleEnd = Date(timeIntervalSince1970: end / 1000)
        }
        usage.message = (object["displayMessage"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let hasData = usage.usedPercent != nil || usage.autoPercent != nil || usage.spendLimitUSD != nil
        return hasData ? usage : nil
    }

    /// Meters in the same shape as Claude's, for one usage view.
    public var limits: [PlanUsage.Limit] {
        var limits: [PlanUsage.Limit] = []
        if let usedPercent {
            limits.append(.init(name: "Included usage", percent: Int(usedPercent.rounded()), resetsAt: cycleEnd, resetText: nil))
        }
        if let autoPercent {
            limits.append(.init(name: "Auto", percent: Int(autoPercent.rounded()), resetsAt: nil, resetText: nil))
        }
        if let apiPercent {
            limits.append(.init(name: "Named models", percent: Int(apiPercent.rounded()), resetsAt: nil, resetText: nil))
        }
        if let spendLimitUSD, spendLimitUSD > 0 {
            let used = spendUsedUSD ?? 0
            limits.append(.init(name: "Spend limit", percent: Int(min(used / spendLimitUSD * 100, 100).rounded()), resetsAt: nil,
                                resetText: nil))
        }
        return limits
    }

    /// Connect JSON sends 64-bit integers as strings.
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    init(fetchedAt: Date) {
        self.fetchedAt = fetchedAt
    }
}

public enum CursorUsageError: Error, Equatable {
    case unauthorized
    case http(Int)
    case unreadable
}

/// Calls Cursor's usage endpoint with the signed-in user's access token.
public struct CursorUsageClient: Sendable {
    public static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    public init() {}

    public func fetch(token: String) async throws -> CursorUsage {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw CursorUsageError.unauthorized }
        guard status == 200 else { throw CursorUsageError.http(status) }
        guard let usage = CursorUsage.parse(data) else { throw CursorUsageError.unreadable }
        return usage
    }
}
