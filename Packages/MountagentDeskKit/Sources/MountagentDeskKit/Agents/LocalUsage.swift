import Foundation

/// What the agents' work would cost at API prices, read from the logs the CLIs keep on this
/// Mac: Claude Code's `~/.claude/projects/*/*.jsonl` and Codex's `~/.codex/sessions/`. It
/// covers every turn, in Mountagent Desk or in a terminal. An estimate of API-equivalent
/// spend, not a subscription bill.
public enum LocalUsage {
    /// Tokens and their cost for one day, agent, model and working folder.
    public struct Entry: Codable, Equatable, Sendable {
        public var day: String
        public var agent: AgentKind
        public var model: String
        public var folder: String
        public var input = 0
        public var cacheWrite = 0
        public var cacheRead = 0
        public var output = 0
        /// Nil when the model has no price.
        public var costUSD: Double?

        public var tokens: Int { input + cacheWrite + cacheRead + output }

        var key: String { "\(day)|\(agent.rawValue)|\(model)|\(folder)" }

        /// The same day, agent, model and folder with nothing counted yet.
        var empty: Entry { Entry(day: day, agent: agent, model: model, folder: folder) }

        mutating func add(_ other: Entry) {
            input += other.input
            cacheWrite += other.cacheWrite
            cacheRead += other.cacheRead
            output += other.output
            if let cost = other.costUSD { costUSD = (costUSD ?? 0) + cost }
        }

        mutating func remove(_ other: Entry) {
            input -= other.input
            cacheWrite -= other.cacheWrite
            cacheRead -= other.cacheRead
            output -= other.output
            if let cost = other.costUSD { costUSD = (costUSD ?? 0) - cost }
        }
    }

    /// How far each log has been read and what it added up to. The logs only grow, so a
    /// changed one is read from where the last scan stopped.
    public struct Cache: Codable, Sendable {
        var files: [String: FileState] = [:]
        /// The prices the costs were worked out with; others start the cache over.
        var prices: [String: ModelPrices.Price] = [:]
        public init() {}
    }

    /// Every entry, merged across files; `cache` is updated with what was read.
    public static func scan(claudeRoot: URL = defaultClaudeRoot, codexRoot: URL = CodexLimits.home.appendingPathComponent("sessions"),
                            prices: ModelPrices = .builtIn, cache: inout Cache) -> [Entry] {
        if cache.prices != prices.prices { cache = Cache() }
        cache.prices = prices.prices
        var seen: Set<String> = []
        var merged: [String: Entry] = [:]
        for (root, agent) in [(claudeRoot, AgentKind.claude), (codexRoot, AgentKind.codex)] {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = values?.contentModificationDate ?? .distantPast
                let size = values?.fileSize ?? 0
                seen.insert(file.path)
                var state = cache.files[file.path] ?? FileState()
                if state.modified != modified || state.offset != size {
                    // Shorter than what was read: written anew.
                    if size < state.offset { state = FileState() }
                    state.read(file, agent: agent, prices: prices)
                    state.modified = modified
                    cache.files[file.path] = state
                }
                for entry in state.entries.values { merged[entry.key, default: entry.empty].add(entry) }
            }
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        return merged.values.sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }

    public static var defaultClaudeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    static func claudeEntries(_ text: String, prices: ModelPrices) -> [Entry] {
        var state = FileState()
        state.feed(Data(text.utf8), agent: .claude, prices: prices)
        return Array(state.entries.values)
    }

    static func codexEntries(_ text: String, prices: ModelPrices) -> [Entry] {
        var state = FileState()
        state.feed(Data(text.utf8), agent: .codex, prices: prices)
        return Array(state.entries.values)
    }

    /// One log: how far it's been read, what it added up to, and what a later line needs
    /// from earlier ones.
    struct FileState: Codable, Sendable {
        var modified = Date.distantPast
        var offset = 0
        var entries: [String: Entry] = [:]
        /// Claude: the last message, whose further blocks may follow.
        var lastID: String?
        var lastEntry: Entry?
        /// Codex: the model and folder in force, and the running totals.
        var model = "unknown"
        var folder = ""
        var totals: [String: Int] = [:]

        /// Reads whole lines from `offset` on.
        mutating func read(_ file: URL, agent: AgentKind, prices: ModelPrices) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.readToEnd(),
                  let last = data.lastIndex(of: 0x0A)
            else { return }
            let complete = data[data.startIndex...last]
            feed(complete, agent: agent, prices: prices)
            offset += complete.count
        }

        mutating func feed(_ data: Data, agent: AgentKind, prices: ModelPrices) {
            for line in data.split(separator: 0x0A) {
                if agent == .claude { claude(line, prices: prices) } else { codex(line, prices: prices) }
            }
        }

        private static let usageMark = Data(#""usage""#.utf8)
        private static let assistantMark = Data(#""assistant""#.utf8)
        private static let codexMarks = [#""turn_context""#, #""session_meta""#, #""token_count""#].map { Data($0.utf8) }

        private static func object(_ line: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }

        /// One line per streamed block, all carrying the message's usage: a message counts
        /// once, however many lines it spans (they come one after another).
        private mutating func claude(_ line: Data, prices: ModelPrices) {
            guard line.range(of: Self.usageMark) != nil, line.range(of: Self.assistantMark) != nil,
                  let object = Self.object(line), object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>"
            else { return }
            let input = usage["input_tokens"] as? Int ?? 0
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let write = usage["cache_creation_input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let hourWrites = (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
            var entry = Entry(day: LocalUsage.day(object["timestamp"] as? String), agent: .claude, model: model,
                              folder: object["cwd"] as? String ?? "", input: input, cacheWrite: write, cacheRead: read, output: output)
            if let price = prices.price(for: model, promptTokens: input + read + write) {
                var cost = (Double(input) * price.input + Double(read) * price.cacheRead
                    + Double(write - hourWrites) * price.input * 1.25 + Double(hourWrites) * price.input * 2
                    + Double(output) * price.output) / 1_000_000
                if usage["speed"] as? String == "fast" { cost *= 2 }
                entry.costUSD = cost
            }
            let id = message["id"] as? String
            if let id, id == lastID, let previous = lastEntry { entries[previous.key]?.remove(previous) }
            entries[entry.key, default: entry.empty].add(entry)
            lastID = id
            lastEntry = entry
        }

        /// `token_count` events carry running totals: each one's growth is that call's use,
        /// priced at the model the turn ran (`turn_context`).
        private mutating func codex(_ line: Data, prices: ModelPrices) {
            guard Self.codexMarks.contains(where: { line.range(of: $0) != nil }),
                  let object = Self.object(line), let payload = object["payload"] as? [String: Any]
            else { return }
            if let cwd = payload["cwd"] as? String { folder = cwd }
            if let name = payload["model"] as? String { model = name }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any]
            else { return }
            func grown(_ key: String) -> Int {
                let now = total[key] as? Int ?? 0
                defer { totals[key] = now }
                return max(0, now - (totals[key] ?? 0))
            }
            let input = grown("input_tokens"), cached = grown("cached_input_tokens"), output = grown("output_tokens")
            guard input + output > 0 else { return }
            let call = (info["last_token_usage"] as? [String: Any])?["input_tokens"] as? Int ?? input
            var entry = Entry(day: LocalUsage.day(object["timestamp"] as? String), agent: .codex, model: model, folder: folder,
                              input: input - min(cached, input), cacheRead: min(cached, input), output: output)
            if let price = prices.price(for: model, promptTokens: call) {
                entry.costUSD = (Double(entry.input) * price.input + Double(entry.cacheRead) * price.cacheRead + Double(output) * price.output) / 1_000_000
            }
            entries[entry.key, default: entry.empty].add(entry)
        }
    }

    /// Tokens and cost added up; `unpricedTokens` belong to models without a price.
    public struct Total: Equatable, Sendable {
        public var tokens = 0
        public var costUSD = 0.0
        public var unpricedTokens = 0
        public init() {}
    }

    /// The last `count` days (today included, nil for all) of one agent, or all agents,
    /// optionally only work in `folder` and its worktrees.
    public static func total(of entries: [Entry], agent: AgentKind? = nil, folder: String? = nil, lastDays count: Int?, now: Date = .now) -> Total {
        let days: Set<String>? = count.map { count in
            Set((0..<count).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now).map(UsageLedger.key) })
        }
        var total = Total()
        for entry in entries {
            if let agent, entry.agent != agent { continue }
            if let days, !days.contains(entry.day) { continue }
            if let folder, !contains(folder, entry.folder) { continue }
            total.tokens += entry.tokens
            if let cost = entry.costUSD { total.costUSD += cost } else { total.unpricedTokens += entry.tokens }
        }
        return total
    }

    /// Per model, costliest first.
    public static func byModel(_ entries: [Entry], agent: AgentKind? = nil, lastDays count: Int?, now: Date = .now) -> [(model: String, total: Total)] {
        Set(entries.map(\.model))
            .map { model in (model, total(of: entries.filter { $0.model == model }, agent: agent, lastDays: count, now: now)) }
            .filter { $0.1.tokens > 0 }
            .sorted { ($0.1.costUSD, $0.1.tokens) > ($1.1.costUSD, $1.1.tokens) }
    }

    /// `folder` itself, anything inside it, or one of its `<folder>.worktrees/`.
    static func contains(_ folder: String, _ path: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/") || path.hasPrefix(base + ".worktrees/")
    }

    /// `yyyy-MM-dd` in the local time zone.
    static func day(_ timestamp: String?) -> String {
        let date = timestamp.flatMap { try? Date($0, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) }
            ?? timestamp.flatMap { try? Date($0, strategy: .iso8601) } ?? .now
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// API prices in USD per million tokens. Cache writes are priced from the input price (5-minute
/// writes 1.25×, 1-hour 2×), as Anthropic bills them. Users can add or correct models in
/// `model-prices.json` in the data folder.
public struct ModelPrices: Sendable {
    public struct Price: Codable, Equatable, Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// Prompts longer than this (tokens per request) bill at `long`.
        public var longAbove: Int?
        public var long: LongPrice?

        public struct LongPrice: Codable, Equatable, Sendable {
            public var input: Double
            public var output: Double
            public var cacheRead: Double
        }

        public init(input: Double, output: Double, cacheRead: Double, longAbove: Int? = nil, long: LongPrice? = nil) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.longAbove = longAbove
            self.long = long
        }
    }

    public var prices: [String: Price]

    /// From Anthropic's and OpenAI's price lists as of October 2026.
    public static let builtIn = ModelPrices(prices: [
        "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.50),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-4-6": Price(input: 3, output: 15, cacheRead: 0.30),
        "claude-haiku-5-5": Price(input: 0.10, output: 0.50, cacheRead: 0.01, longAbove: 100_000, long: .init(input: 0.50, output: 2.50, cacheRead: 0.05)),
        "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.10),
        "gpt-6-luna": Price(input: 0.10, output: 0.50, cacheRead: 0.01, longAbove: 272_000, long: .init(input: 0.20, output: 0.75, cacheRead: 0.02)),
    ])

    public init(prices: [String: Price]) {
        self.prices = prices
    }

    /// The built-in list with the user's own prices over it.
    public func merging(_ overrides: [String: Price]) -> ModelPrices {
        ModelPrices(prices: prices.merging(overrides) { $1 })
    }

    /// Exact id first; a dated id (`claude-haiku-4-5-20251001`) falls back to its base.
    public func price(for model: String, promptTokens: Int = 0) -> Price? {
        let base = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        guard let price = prices[model] ?? prices[base] else { return nil }
        if let limit = price.longAbove, let long = price.long, promptTokens > limit {
            return Price(input: long.input, output: long.output, cacheRead: long.cacheRead)
        }
        return price
    }
}
