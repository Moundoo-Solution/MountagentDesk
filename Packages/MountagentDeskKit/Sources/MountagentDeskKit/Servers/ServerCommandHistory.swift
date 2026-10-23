import Foundation

/// Commands run on one server, as Termius keeps them: what the user typed in the app's
/// terminals, plus whatever they load from the server's own shell history. Pinned
/// commands stay on top; the rest are newest first and capped.
public struct ServerCommandHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var command: String
        public var lastUsed: Date
        public var pinned: Bool
        public var id: String { command }
    }

    public private(set) var entries: [Entry] = []
    static let limit = 500

    public init() {}

    /// Pinned first, then newest first.
    public var ordered: [Entry] {
        entries.sorted { ($0.pinned ? 1 : 0, $0.lastUsed) > ($1.pinned ? 1 : 0, $1.lastUsed) }
    }

    /// Adds a command just run, or moves it to the top if it is already there.
    public mutating func record(_ command: String, at date: Date = .now) {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.command == command }) {
            entries[index].lastUsed = date
        } else {
            entries.append(Entry(command: command, lastUsed: date, pinned: false))
        }
        trim()
    }

    /// Commands from the server's history file (oldest first), placed below everything
    /// already known, in their own order.
    public mutating func merge(imported commands: [String], before date: Date? = nil) {
        let known = Set(entries.map(\.command))
        let start = (date ?? entries.map(\.lastUsed).min() ?? .now).addingTimeInterval(-Double(commands.count) - 1)
        for (offset, command) in commands.enumerated() where !known.contains(command) {
            entries.append(Entry(command: command, lastUsed: start.addingTimeInterval(Double(offset)), pinned: false))
        }
        trim()
    }

    public mutating func togglePin(_ command: String) {
        guard let index = entries.firstIndex(where: { $0.command == command }) else { return }
        entries[index].pinned.toggle()
    }

    public mutating func remove(_ command: String) {
        entries.removeAll { $0.command == command }
    }

    private mutating func trim() {
        let unpinned = entries.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        guard unpinned.count > Self.limit else { return }
        let dropped = Set(unpinned.dropFirst(Self.limit).map(\.command))
        entries.removeAll { !$0.pinned && dropped.contains($0.command) }
    }

    // MARK: Reading commands

    /// The command on the terminal's last line when Return is pressed: rows the shell
    /// wrapped (full width) are joined, the prompt (`user@host:~$ `) is dropped. Nil for
    /// lines without a shell prompt and for password prompts.
    public static func commandLine(fromScreen text: String, columns: Int) -> String? {
        var lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard var line = lines.popLast() else { return nil }
        // A full-width row before this one is the start of the same, wrapped line.
        while let previous = lines.last, columns > 0, previous.count >= columns {
            line = previous + line
            lines.removeLast()
        }
        // The shortest prefix ending in a prompt sign: `$ `, `# `, `% ` or `dir> `.
        guard !line.localizedCaseInsensitiveContains("password"),
              let prompt = line.range(of: #"^.*?(?:[$#%]|[A-Za-z0-9_~/\])]>) "#, options: .regularExpression)
        else { return nil }
        let command = line[prompt.upperBound...].trimmingCharacters(in: .whitespaces)
        return command.isEmpty || looksSecret(command) ? nil : command
    }

    /// Commands that carry a secret on the line (`API_KEY=…`, `--password x`, `mysql -pX`,
    /// `Authorization: …`, `user:pass@` in a URL) aren't kept: history is plain JSON that any
    /// agent can read.
    public static func looksSecret(_ command: String) -> Bool {
        secretPatterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static let secretPatterns = [
        #"[a-z0-9_]*(pass(word|wd)?|pwd|secret|token|api_?key|access_?key|private_?key|credentials?)[a-z0-9_]*\s*="#,
        #"--?(password|passwd|pass|token|secret|api-?key|access-?key|auth|credentials?)([= ]|$)"#,
        #"(^|\s)mysql(dump|admin)?\b.*\s-p\S"#,
        #"authorization:|bearer\s+\S"#,
        #"://[^/\s:@]+:[^/\s@]+@"#,
        #"(^|\s)(curl|wget)\b.*\s(-u|--user)[= ]?\S+:\S"#,
        #"(^|\s)sshpass\s"#,
    ]

    /// `~/.bash_history` or `~/.zsh_history`: one command per line, oldest first, without
    /// bash's `#1700000000` timestamps and zsh's `: 1700000000:0;` prefixes, repeats
    /// kept at their last use.
    public static func parseShellHistory(_ text: String) -> [String] {
        var seen = Set<String>()
        var commands: [String] = []
        for raw in text.components(separatedBy: .newlines).reversed() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.wholeMatch(of: /#\d+/) != nil { continue }
            if let match = line.firstMatch(of: /^: \d+:\d+;/) { line = String(line[match.range.upperBound...]) }
            guard !line.isEmpty, !looksSecret(line), seen.insert(line).inserted else { continue }
            commands.append(line)
        }
        return commands.reversed()
    }

    /// Reads both shells' history files; the last 1,000 lines are plenty.
    public static let readCommand = "cat ~/.bash_history ~/.zsh_history 2>/dev/null | tail -n 1000"
}
