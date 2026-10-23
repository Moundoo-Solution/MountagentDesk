import Foundation
import Security

/// What Mountagent Desk knows about an agent's CLI and the account it is signed in to.
public struct AgentAccount: Equatable, Sendable {
    public var kind: AgentKind
    public var executable: String?
    public var version: String?
    public var latestVersion: String?
    public var loggedIn: Bool
    public var email: String?
    public var plan: String?
    public var organization: String?
    public var authMethod: String?

    public init(kind: AgentKind) {
        self.kind = kind
        self.loggedIn = false
    }

    public var isInstalled: Bool { executable != nil }
    public var updateAvailable: Bool { latestVersion != nil && latestVersion != version }
}

/// Reads account details from each CLI's own status commands.
public struct AccountProbe: Sendable {
    public var runner: AgentRunner
    /// The GitHub account Copilot runs as (its `gh` token), when one is chosen.
    public var copilotLogin: String?

    public init(runner: AgentRunner, copilotLogin: String? = nil) {
        self.runner = runner
        self.copilotLogin = copilotLogin
    }

    public func probe(_ kind: AgentKind) -> AgentAccount {
        var account = AgentAccount(kind: kind)
        guard let executable = runner.locator.locate(kind) else { return account }
        account.executable = executable.path
        switch kind {
        case .claude:
            if let version = try? runner.capture(.claude, arguments: ["--version"], timeout: 15) {
                account.version = version.split(separator: " ").first.map(String.init)
            }
            if let status = try? runner.capture(.claude, arguments: ["auth", "status"], timeout: 20) {
                Self.applyClaudeStatus(status, to: &account)
            }
        case .cursor:
            if let about = try? runner.capture(.cursor, arguments: ["about", "--format", "json"], timeout: 20) {
                Self.applyCursorAbout(about, to: &account)
            }
            if let status = try? runner.capture(.cursor, arguments: ["status", "--format", "json"], timeout: 20),
               let object = JSONLine.object(Self.jsonPart(of: status)) {
                account.loggedIn = object["isAuthenticated"] as? Bool ?? (object["status"] as? String == "authenticated")
                account.email = account.email ?? object["email"] as? String
            }
        case .codex:
            if let version = try? runner.capture(.codex, arguments: ["--version"], timeout: 15) {
                account.version = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last.map(String.init)
            }
            if let status = try? runner.capture(.codex, arguments: ["login", "status"], timeout: 20) {
                Self.applyCodexStatus(status, to: &account)
            }
            // `login status` names no account; the login's identity part does.
            if account.authMethod == "ChatGPT" {
                let signedIn = CodexLimits.account()
                account.email = signedIn.email
                if let plan = signedIn.plan { account.plan = plan }
            }
        case .antigravity:
            if let version = try? runner.capture(.antigravity, arguments: ["--version"], timeout: 20) {
                account.version = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            }
            // `agy models` needs a signed-in account and says so otherwise.
            let models = (try? runner.capture(.antigravity, arguments: ["models"], timeout: 30)) ?? ""
            account.loggedIn = !models.isEmpty && !models.localizedCaseInsensitiveContains("sign in")
            account.authMethod = account.loggedIn ? "Google account" : nil
            account.plan = account.authMethod
        case .copilot:
            if let version = try? runner.capture(.copilot, arguments: ["--version"], timeout: 20) {
                account.version = CopilotProvider.parseVersion(version)
            }
            if let login = copilotLogin, GitHubCLI.token(for: login) != nil {
                account.loggedIn = true
                account.email = login
                account.authMethod = "GitHub account (gh)"
            } else {
                // `copilot login` keeps who signed in in its config file.
                let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot/config.json")
                let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                account.loggedIn = text.contains("logged_in") || text.contains("loggedIn")
                account.authMethod = account.loggedIn ? "copilot login" : nil
            }
            account.plan = account.loggedIn ? "Copilot" : nil
        case .gemini:
            if let version = try? runner.capture(.gemini, arguments: ["--version"], timeout: 20) {
                account.version = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            }
            account.authMethod = Self.geminiAuth()
            account.loggedIn = account.authMethod != nil
            account.plan = account.authMethod
        case .opencode:
            if let version = try? runner.capture(.opencode, arguments: ["--version"], timeout: 20) {
                account.version = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
            }
            let providers = Self.openCodeProviders()
            account.loggedIn = !providers.isEmpty
            account.authMethod = providers.isEmpty ? nil : providers.joined(separator: ", ")
            account.plan = account.authMethod
        }
        return account
    }

    /// How Gemini CLI would sign in headless, or nil when it couldn't: an API key in the
    /// environment, `~/.gemini/.env` or the keychain, a Google sign-in it saved, or the
    /// Vertex AI / Cloud credentials chosen in its settings.
    static func geminiAuth(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment,
                           inKeychain: (String) -> Bool = Self.keychainHasItem) -> String? {
        let folder = home.appendingPathComponent(".gemini")
        let keys = ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        if keys.contains(where: { environment[$0]?.isEmpty == false }) || inKeychain("gemini-cli-api-key") { return "Gemini API key" }
        let dotenv = (try? String(contentsOf: folder.appendingPathComponent(".env"), encoding: .utf8)) ?? ""
        let setInFile = dotenv.split(separator: "\n").contains { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            return keys.contains { line.hasPrefix($0 + "=") && line.count > $0.count + 1 }
        }
        if setInFile { return "Gemini API key" }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("oauth_creds.json").path) || inKeychain("gemini-cli-oauth") {
            return "Google account"
        }
        let settings = (try? Data(contentsOf: folder.appendingPathComponent("settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject }
        let selected = ((settings?["security"] as? JSONObject)?["auth"] as? JSONObject)?["selectedType"] as? String
        return switch selected {
        case "vertex-ai": "Vertex AI"
        case "compute-default-credentials": "Cloud credentials"
        default: nil
        }
    }

    /// Whether the keychain has a password for `service`. Only its attributes are asked
    /// for, so macOS doesn't prompt and the secret is never read.
    static func keychainHasItem(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The providers `opencode auth login` saved (their names only), in its data folder.
    static func openCodeProviders(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let data = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        let file = data.appendingPathComponent("opencode/auth.json")
        guard let contents = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: contents) as? JSONObject
        else { return [] }
        return object.keys.sorted()
    }

    /// `claude auth status` prints JSON: loggedIn, email, orgName, subscriptionType, authMethod.
    static func applyClaudeStatus(_ output: String, to account: inout AgentAccount) {
        guard let object = JSONLine.object(jsonPart(of: output)) else { return }
        account.loggedIn = object["loggedIn"] as? Bool ?? false
        account.email = object["email"] as? String
        account.organization = object["orgName"] as? String
        account.plan = (object["subscriptionType"] as? String).map { $0.capitalized }
        account.authMethod = object["authMethod"] as? String
    }

    /// `codex login status`: "Logged in using ChatGPT", "Logged in using an API key…", "Not logged in".
    static func applyCodexStatus(_ output: String, to account: inout AgentAccount) {
        let line = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("Logged in") || $0.hasPrefix("Not logged in") } ?? ""
        account.loggedIn = line.hasPrefix("Logged in")
        if account.loggedIn {
            account.authMethod = line.localizedCaseInsensitiveContains("ChatGPT") ? "ChatGPT" : "API key"
            account.plan = account.authMethod == "ChatGPT" ? "ChatGPT" : "API"
        }
    }

    /// `cursor-agent about --format json`: cliVersion, latestVersion, subscriptionTier, userEmail.
    static func applyCursorAbout(_ output: String, to account: inout AgentAccount) {
        guard let object = JSONLine.object(jsonPart(of: output)) else { return }
        account.version = object["cliVersion"] as? String
        if object["latestStatus"] as? String == "update_available" {
            account.latestVersion = object["latestVersion"] as? String
        }
        account.plan = object["subscriptionTier"] as? String
        account.email = object["userEmail"] as? String
    }

    /// Commands may print a notice before their JSON; take the object itself.
    static func jsonPart(of output: String) -> String {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return output }
        return String(output[start...end])
    }
}

/// Commands that set an agent up, run in a terminal so their prompts and browser
/// sign-in work as they do in Terminal.app.
public enum AgentSetup {
    public static func installCommand(for kind: AgentKind) -> String {
        switch kind {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .cursor: "curl https://cursor.com/install -fsS | bash"
        case .codex: "if command -v brew >/dev/null; then brew install --cask codex; else npm install -g @openai/codex; fi"
        // Google's installer: a checksummed Go binary into ~/.local/bin.
        case .antigravity: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        case .copilot: "npm install -g @github/copilot"
        case .gemini: "npm install -g @google/gemini-cli"
        case .opencode: "npm install -g opencode-ai"
        }
    }

    /// After an install `executable` is nil; the bare name is found through the terminal's
    /// PATH, which includes ~/.local/bin, Homebrew and npm's folders.
    public static func loginCommand(for kind: AgentKind, executable: String?) -> String {
        let cli = executable.map(Shell.quote) ?? kind.executableName
        return switch kind {
        case .claude: "\(cli) auth login"
        case .cursor, .codex, .copilot: "\(cli) login"
        // Started bare, Gemini CLI asks how to sign in; OpenCode signs in per model provider.
        case .gemini: cli
        case .opencode: "\(cli) auth login"
        // `agy` has no login command: started bare, it signs in through the browser.
        case .antigravity: cli
        }
    }

    /// What to do in the terminal while signing in, where it isn't the usual browser round trip.
    public static func loginHint(for kind: AgentKind) -> String? {
        switch kind {
        case .antigravity: "Antigravity opens Google sign-in in your browser and picks it up by itself. If the browser shows a code instead, paste it below. When Antigravity's prompt appears, press Finish."
        default: nil
        }
    }

    /// A sign-in that may print a link and ask for a code typed back, while the CLI itself
    /// keeps running afterwards (it is closed with Finish).
    public struct SignInFlow: Sendable {
        /// The sign-in link starts with this; it gets an Open button.
        public var linkPrefix: String
        /// Text shown while the CLI waits for a pasted code.
        public var codePrompt: String
    }

    public static func signInFlow(for kind: AgentKind) -> SignInFlow? {
        switch kind {
        case .antigravity: SignInFlow(linkPrefix: "https://accounts.google.com/", codePrompt: "authorization code")
        default: nil
        }
    }

    /// The first complete link in terminal output that starts with `prefix`.
    public static func link(in output: String, prefix: String) -> URL? {
        guard let start = output.range(of: prefix) else { return nil }
        let tail = output[start.lowerBound...]
        // The CLI prints the link on its own line; it ends at whitespace or an escape sequence.
        guard let end = tail.firstIndex(where: { $0.isWhitespace || $0 == "\u{1B}" || $0 == "\u{07}" }) else { return nil }
        return URL(string: String(tail[..<end]))
    }

    /// `nil` where the CLI has no sign-out command (Antigravity signs out from its own prompt).
    public static func logoutCommand(for kind: AgentKind, executable: String?) -> String? {
        let cli = executable.map(Shell.quote) ?? kind.executableName
        return switch kind {
        case .claude: "\(cli) auth logout"
        case .cursor, .codex: "\(cli) logout"
        case .antigravity, .copilot, .gemini: nil
        case .opencode: "\(cli) auth logout"
        }
    }

    public static func updateCommand(for kind: AgentKind, executable: String?) -> String {
        let cli = executable.map(Shell.quote) ?? kind.executableName
        let viaBrew = executable.map { $0.hasPrefix("/opt/homebrew/") || $0.hasPrefix("/usr/local/") } ?? false
        return switch kind {
        case .claude, .cursor, .antigravity, .copilot: "\(cli) update"
        case .codex: viaBrew ? "brew upgrade --cask codex" : "npm install -g @openai/codex@latest"
        case .gemini: "npm install -g @google/gemini-cli@latest"
        case .opencode: "\(cli) upgrade"
        }
    }

    /// Where each service shows plan usage in the browser.
    public static func usagePage(for kind: AgentKind) -> URL {
        switch kind {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .cursor: URL(string: "https://cursor.com/dashboard?tab=usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .antigravity: URL(string: "https://antigravity.google")!
        case .copilot: URL(string: "https://github.com/settings/billing/premium_requests_usage")!
        case .gemini: URL(string: "https://aistudio.google.com/usage")!
        case .opencode: URL(string: "https://opencode.ai/docs/providers/")!
        }
    }
}

/// Claude's plan limits as reported with every turn (`rate_limit_event`).
public struct RateLimitInfo: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var name: String
        public var utilization: Double
        public var resetsAt: Date?
    }

    public var windows: [Window]
    public var observedAt: Date

    public init(windows: [Window], observedAt: Date = .now) {
        self.windows = windows
        self.observedAt = observedAt
    }

    /// "five_hour" → "5-hour limit".
    public static func title(of window: String) -> String {
        switch window {
        case "five_hour": "5-hour limit"
        case "seven_day": "Weekly limit"
        case "seven_day_opus": "Weekly limit (Opus)"
        case "seven_day_sonnet": "Weekly limit (Sonnet)"
        default: window.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Tokens and cost per agent per day, kept across launches.
public struct UsageLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var turns = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var costUSD = 0.0
        public var hasCost = false

        public var totalTokens: Int { inputTokens + outputTokens }

        mutating func add(_ other: Entry) {
            turns += other.turns
            inputTokens += other.inputTokens
            outputTokens += other.outputTokens
            costUSD += other.costUSD
            hasCost = hasCost || other.hasCost
        }
    }

    /// `agent rawValue` → `yyyy-MM-dd` → totals.
    public var days: [String: [String: Entry]] = [:]
    /// The same per project (`project id` → `yyyy-MM-dd` → totals), for a client's share.
    public var projects: [String: [String: Entry]] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case days, projects }

    // Ledgers saved before the per-project totals have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decodeIfPresent([String: [String: Entry]].self, forKey: .days) ?? [:]
        projects = try container.decodeIfPresent([String: [String: Entry]].self, forKey: .projects) ?? [:]
    }

    public mutating func record(_ result: TurnResult, agent: AgentKind, project: UUID? = nil, on date: Date = .now) {
        var turn = Entry()
        turn.turns = 1
        turn.inputTokens = result.inputTokens ?? 0
        turn.outputTokens = result.outputTokens ?? 0
        if let cost = result.costUSD {
            turn.costUSD = cost
            turn.hasCost = true
        }
        days[agent.rawValue, default: [:]][Self.key(date), default: Entry()].add(turn)
        if let project { projects[project.uuidString, default: [:]][Self.key(date), default: Entry()].add(turn) }
    }

    /// A project's totals for the last `count` days, today included.
    public func total(forProject project: UUID, lastDays count: Int, now: Date = .now) -> Entry {
        total(in: projects[project.uuidString] ?? [:], lastDays: count, now: now)
    }

    /// `date,project,turns,input tokens,output tokens,cost (USD)`, oldest first.
    public func projectCSV(names: [UUID: String]) -> String {
        var rows = ["date,project,turns,input_tokens,output_tokens,cost_usd"]
        let lines = projects.flatMap { id, days in
            days.map { day, entry in (day, UUID(uuidString: id).flatMap { names[$0] } ?? id, entry) }
        }
        for (day, name, entry) in lines.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            rows.append("\(day),\(quoted),\(entry.turns),\(entry.inputTokens),\(entry.outputTokens),\(entry.hasCost ? String(format: "%.4f", entry.costUSD) : "")")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Totals for the last `days` days, today included.
    public func total(for agent: AgentKind, lastDays count: Int, now: Date = .now) -> Entry {
        total(in: days[agent.rawValue] ?? [:], lastDays: count, now: now)
    }

    private func total(in days: [String: Entry], lastDays count: Int, now: Date) -> Entry {
        var total = Entry()
        let calendar = Calendar.current
        for offset in 0..<count {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now),
                  let entry = days[Self.key(day)]
            else { continue }
            total.add(entry)
        }
        return total
    }

    static func key(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// Plan usage as Claude Code's `/usage` reports it ("Current session: 55% used · resets …").
/// Read with `claude -p /usage`, which answers locally: no model call, no cost.
public struct PlanUsage: Codable, Equatable, Sendable {
    public struct Limit: Codable, Equatable, Sendable {
        public var name: String
        public var percent: Int
        public var resetsAt: Date?
        /// The CLI's own wording, kept when the date can't be read.
        public var resetText: String?
    }

    public var limits: [Limit]
    /// "Last 24h · 726 requests · 42 sessions" and the observations under it.
    public var notes: [String]
    public var fetchedAt: Date

    public init(limits: [Limit], notes: [String] = [], fetchedAt: Date = .now) {
        self.limits = limits
        self.notes = notes
        self.fetchedAt = fetchedAt
    }

    /// Claude's own names for its two main limits, as `/usage` prints them.
    static let sessionLimit = "Session (5hr)"
    static let weeklyLimit = "Weekly (7 day)"

    public static func parse(_ text: String, now: Date = .now) -> PlanUsage? {
        var limits: [Limit] = []
        var notes: [String] = []
        var inNotes = false
        let pattern = /^Current (session|week(?: \((.+?)\))?): (\d+)% used(?: · resets (.+))?$/
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.wholeMatch(of: pattern) {
                let name = match.1 == "session" ? sessionLimit : match.2.map { "Weekly (\($0))" } ?? weeklyLimit
                let reset = match.4.map { String($0).replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression) }
                limits.append(Limit(name: name, percent: Int(match.3) ?? 0, resetsAt: reset.flatMap { resetDate($0, now: now) }, resetText: reset))
            } else if line.hasPrefix("Last ") {
                inNotes = true
                notes.append(line)
            } else if inNotes, !line.isEmpty {
                notes.append(line)
            }
        }
        return limits.isEmpty ? nil : PlanUsage(limits: limits, notes: notes, fetchedAt: now)
    }

    /// "Oct 20 at 11:49am" or "11:49am" in the local time zone, the next such moment.
    static func resetDate(_ text: String, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        let calendar = Calendar.current
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha"] {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }
            var components = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
            if !format.hasPrefix("MMM") {
                let today = calendar.dateComponents([.month, .day], from: now)
                components.month = today.month
                components.day = today.day
            }
            components.year = calendar.component(.year, from: now)
            guard var date = calendar.date(from: components) else { continue }
            while date < now.addingTimeInterval(-3600) {
                date = calendar.date(byAdding: format.hasPrefix("MMM") ? .year : .day, value: 1, to: date) ?? date
            }
            return date
        }
        return nil
    }

    /// Fresher percentages from a turn's `rate_limit_event`, keeping the `/usage` notes.
    public func updated(with info: RateLimitInfo) -> PlanUsage {
        var copy = self
        for window in info.windows {
            let name = window.name == "five_hour" ? Self.sessionLimit : window.name == "seven_day" ? limits.first { $0.name.hasPrefix("Weekly") }?.name : nil
            guard let name, let index = copy.limits.firstIndex(where: { $0.name == name }) else { continue }
            copy.limits[index].percent = Int((window.utilization * 100).rounded())
            if let reset = window.resetsAt { copy.limits[index].resetsAt = reset }
        }
        copy.fetchedAt = info.observedAt
        return copy
    }

    public static func from(_ info: RateLimitInfo) -> PlanUsage {
        PlanUsage(limits: info.windows.map { window in
            Limit(name: window.name == "five_hour" ? sessionLimit : window.name == "seven_day" ? weeklyLimit : RateLimitInfo.title(of: window.name),
                  percent: Int((window.utilization * 100).rounded()), resetsAt: window.resetsAt, resetText: nil)
        }, fetchedAt: info.observedAt)
    }
}

extension AccountProbe {
    /// Claude's plan usage, or nil when signed out or on API billing.
    public func claudePlanUsage() -> PlanUsage? {
        guard let output = try? runner.capture(.claude, arguments: ["-p", "--no-session-persistence", "--output-format", "json", "/usage"], timeout: 30),
              let object = JSONLine.object(Self.jsonPart(of: output)),
              let result = object["result"] as? String
        else { return nil }
        return PlanUsage.parse(result)
    }
}
