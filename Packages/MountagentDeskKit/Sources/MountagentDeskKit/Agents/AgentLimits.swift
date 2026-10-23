import Foundation

/// Codex's plan limits, as the CLI last saw them. `codex exec` writes them with every turn
/// into its session logs (`~/.codex/sessions/…/rollout-*.jsonl`, a `rate_limits` object), so
/// they're as fresh as the last Codex turn, from Mountagent Desk or anywhere else.
public enum CodexLimits {
    /// `$CODEX_HOME`, or `~/.codex`.
    public static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The limits in the newest session log that has them.
    public static func latest(home: URL = home, now: Date = .now) -> PlanUsage? {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var logs: [(URL, Date)] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            logs.append((file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        for (file, _) in logs.sorted(by: { $0.1 > $1.1 }).prefix(10) {
            if let usage = lastLimits(in: file, now: now) { return usage }
        }
        return nil
    }

    /// The last line of the log that carries limits; only its end is read.
    static func lastLimits(in file: URL, now: Date) -> PlanUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let usage = parse(String(line), now: now) { return usage }
        }
        return nil
    }

    /// One log line: `{"timestamp": …, "payload": {…, "rate_limits": {"primary": …}}}`.
    static func parse(_ line: String, now: Date = .now) -> PlanUsage? {
        guard let object = JSONLine.object(line), let limits = find("rate_limits", in: object) as? [String: Any] else { return nil }
        var result: [PlanUsage.Limit] = []
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double else { continue }
            let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            // A window that has reset since starts again from nothing.
            let percent = resets.map { $0 < now } == true ? 0 : Int(used.rounded())
            result.append(PlanUsage.Limit(name: name(minutes: window["window_minutes"] as? Int), percent: percent, resetsAt: resets.flatMap { $0 < now ? nil : $0 }))
        }
        guard !result.isEmpty else { return nil }
        let stamp = (object["timestamp"] as? String).flatMap { try? Date($0, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) }
        let plan = (limits["plan_type"] as? String).map(planName)
        return PlanUsage(limits: result, notes: plan.map { [$0] } ?? [], fetchedAt: stamp ?? now)
    }

    static func name(minutes: Int?) -> String {
        switch minutes {
        case 300: "5-hour limit"
        case 10_080: "Weekly limit"
        case 43_200: "30-day limit"
        case let minutes? where minutes % 1_440 == 0: "\(minutes / 1_440)-day limit"
        case let minutes? where minutes % 60 == 0: "\(minutes / 60)-hour limit"
        default: "Limit"
        }
    }

    /// `free` → Free, `plus` → Plus, `pro` → Pro.
    static func planName(_ type: String) -> String {
        type.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    /// The signed-in ChatGPT account: email and plan, from the identity part of the login
    /// (`auth.json` → `tokens.id_token`, a JWT whose claims are readable; nothing else in the
    /// file is used).
    public static func account(home: URL = home) -> (email: String?, plan: String?) {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (auth["tokens"] as? [String: Any])?["id_token"] as? String
        else { return (nil, nil) }
        return claims(ofJWT: token)
    }

    static func claims(ofJWT token: String) -> (email: String?, plan: String?) {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return (nil, nil) }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (nil, nil) }
        let plan = ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String).map(planName)
        return (claims["email"] as? String, plan)
    }

    private static func find(_ key: String, in value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let found = object[key], !(found is NSNull) { return found }
            for child in object.values { if let found = find(key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = find(key, in: child) { return found } }
        }
        return nil
    }
}

/// Copilot's monthly quotas (chat, premium requests) from GitHub, for the account Copilot
/// runs as. The endpoint is the one GitHub's own editors use (`/copilot_internal/user`); it
/// isn't documented, so anything unexpected just means no meters.
public enum CopilotLimits {
    public struct Result: Equatable, Sendable {
        public let usage: PlanUsage
        /// Free, Pro, Business…
        public let plan: String?
    }

    public static func fetch(token: String) async -> Result? {
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mountagent Desk", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data, now: Date = .now) -> Result? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let quotas = object["quota_snapshots"] as? [String: Any]
        else { return nil }
        let resets = (object["quota_reset_date"] as? String).flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }
        var limits: [PlanUsage.Limit] = []
        var notes: [String] = []
        for (key, name) in [("premium_interactions", "Premium requests"), ("chat", "Chat")] {
            guard let quota = quotas[key] as? [String: Any], quota["unlimited"] as? Bool != true else { continue }
            if key == "premium_interactions", (quota["entitlement"] as? Double ?? 0) <= 0 {
                notes.append("No premium requests in this plan")
                continue
            }
            guard let remaining = quota["percent_remaining"] as? Double else { continue }
            limits.append(PlanUsage.Limit(name: name, percent: max(0, min(100, Int((100 - remaining).rounded()))), resetsAt: resets))
        }
        guard !limits.isEmpty || !notes.isEmpty else { return nil }
        let sku = (object["access_type_sku"] as? String ?? "").lowercased()
        let plan = sku.contains("free") ? "Free" : (object["copilot_plan"] as? String).map { $0 == "individual" ? "Pro" : $0.capitalized }
        return Result(usage: PlanUsage(limits: limits, notes: notes, fetchedAt: now), plan: plan)
    }
}
