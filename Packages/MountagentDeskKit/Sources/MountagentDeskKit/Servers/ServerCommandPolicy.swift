import Foundation

/// Decides whether an agent's command may run on a server: only commands that read. It
/// reads the command the way `sh` would (quotes, pipes, redirections) and accepts a short
/// list of programs with safe arguments; anything it doesn't understand is refused.
///
/// This is a guard rail for the agent, not a security boundary: the server-side guarantee
/// is an SSH user (and database role) that can only read.
public enum ServerCommandPolicy {
    public enum Verdict: Equatable, Sendable {
        /// Runs as given, with `psql` switched to read-only transactions.
        case allowed(String)
        case blocked(String)
    }

    /// `sudoUsers`: who `sudo -u` may run as on this server (`root` for plain sudo); empty
    /// refuses sudo.
    public static func check(_ command: String, sudoUsers: [String] = []) -> Verdict {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .blocked("The command is empty.") }
        guard !trimmed.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\t" }) else {
            return .blocked("Send one command line, without line breaks.")
        }
        let segments: [[Word]]
        do {
            var lexer = Lexer(trimmed)
            segments = try lexer.segments()
        } catch let error as Refusal {
            return .blocked(error.reason)
        } catch {
            return .blocked("The command couldn't be read.")
        }
        var insertions: [String.Index] = []
        for words in segments {
            switch checkSegment(words, sudoUsers: sudoUsers) {
            case .failure(let refusal): return .blocked(refusal.reason)
            case .success(let insertAt): insertions += insertAt
            }
        }
        var result = trimmed
        for index in insertions.sorted(by: >) {
            result.insert(contentsOf: " -X -c " + Shell.quote(readOnlySession), at: index)
        }
        return .allowed(result)
    }

    /// Sent before each `psql -c` query, so the session can't write even if a check missed something.
    static let readOnlySession = "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY"

    // MARK: Programs

    /// Programs that only read whatever their arguments.
    private static let readers: Set<String> = [
        "cat", "head", "grep", "egrep", "fgrep", "zgrep", "zcat", "bzcat", "xzcat", "ls", "pwd", "wc",
        "cut", "tr", "nl", "column", "stat", "du", "df", "free", "uptime", "whoami", "id",
        "uname", "pgrep", "netstat", "lsof", "last", "w", "who", "echo", "printf",
        "basename", "dirname", "realpath", "readlink", "which", "md5sum", "sha1sum", "sha256sum",
        "diff", "cmp", "tac", "rev", "jq", "nproc", "lscpu", "vmstat", "iostat", "getent",
    ]

    private static func checkSegment(_ words: [Word], sudoUsers: [String]) -> Result<[String.Index], Refusal> {
        guard let first = words.first else { return .failure(Refusal("A command is missing between operators.")) }
        if !first.quoted, first.text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            return .failure(Refusal("Setting environment variables isn't allowed."))
        }
        if first.text == "sudo" { return checkSudo(Array(words.dropFirst()), allowed: sudoUsers) }
        return checkProgram(words)
    }

    /// `sudo [-n] [-H] [-u user] <allowed command>`, for the users this server allows.
    private static func checkSudo(_ words: [Word], allowed: [String]) -> Result<[String.Index], Refusal> {
        guard !allowed.isEmpty else {
            return .failure(Refusal("sudo isn't allowed on this server. The user can allow sudo -u to chosen users in the server's settings."))
        }
        var rest = words[...]
        var target = "root"
        while let word = rest.first, word.text.hasPrefix("-") {
            rest = rest.dropFirst()
            switch word.text {
            case "-n", "-H":
                continue
            case "-u":
                guard let user = rest.popFirst() else { return .failure(Refusal("sudo -u needs a user.")) }
                target = user.text
            default:
                return .failure(Refusal("sudo \(word.text) isn't allowed; use sudo -u <user> <command>."))
            }
        }
        guard allowed.contains(target) else {
            return .failure(Refusal("sudo to \(target) isn't allowed on this server; allowed: \(allowed.joined(separator: ", "))."))
        }
        guard !rest.isEmpty else { return .failure(Refusal("sudo needs a command.")) }
        return checkProgram(Array(rest))
    }

    private static func checkProgram(_ words: [Word]) -> Result<[String.Index], Refusal> {
        let name = words[0].text
        let arguments = words.dropFirst().map(\.text)
        guard !name.contains("/") else {
            return .failure(Refusal("Call \((name as NSString).lastPathComponent) by name, without a path."))
        }
        if readers.contains(name) { return .success([]) }
        let reason: String?
        switch name {
        case "tail": reason = refuseShortFlags(arguments, "fF", long: ["--follow"], "Following a file never ends; use tail -n.")
        case "journalctl": reason = refuseShortFlags(arguments, "f", long: ["--follow", "--vacuum", "--rotate", "--flush", "--sync", "--relinquish-var", "--smart-relinquish-var", "--setup-keys", "--update-catalog"], "Only reading the journal is allowed (no -f, vacuum or rotate).")
        case "sort": reason = refuseShortFlags(arguments, "o", long: ["--output", "--compress-program"], "sort may not write files or run programs (no -o or --compress-program).")
        case "uniq": reason = operands(arguments).count > 1 ? "uniq with two files writes the second." : nil
        case "date": reason = refuseShortFlags(arguments, "s", long: ["--set"], "Only reading the date is allowed.")
            ?? (arguments.contains { !$0.hasPrefix("-") && !$0.hasPrefix("+") } ? "Only reading the date is allowed." : nil)
        case "file": reason = refuseShortFlags(arguments, "C", long: ["--compile"], "file -C writes a compiled magic file.")
        case "ss": reason = refuseShortFlags(arguments, "K", long: ["--kill"], "ss -K closes connections.")
        // BSD-style `e` (`ps auxe`, `ps eww`) prints each process's environment: passwords, tokens.
        case "ps": reason = arguments.contains { !$0.hasPrefix("-") && $0.contains("e") } ? "ps e shows processes' environments (secrets); leave the e out." : nil
        case "hostname": reason = operands(arguments).isEmpty ? nil : "Only reading the host name is allowed."
        case "find": reason = arguments.contains(where: findActions.contains) ? "find may only list files (no -delete, -exec or -fprint)." : nil
        case "top": reason = arguments.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("b") }) && arguments.contains(where: { $0.hasPrefix("-") && $0.contains("n") }) ? nil : "Use top -b -n 1."
        // Not show or cat: they print a unit's Environment= lines, often secrets.
        case "systemctl": reason = checkSubcommand(arguments, allowed: ["status", "is-active", "is-enabled", "is-failed", "list-units", "list-unit-files", "list-timers", "list-dependencies"], emptyAllowed: true)
        case "service": reason = arguments == ["--status-all"] || (arguments.count == 2 && arguments[1] == "status") ? nil : "Only service <name> status is allowed."
        case "docker": reason = checkDocker(arguments)
        case "git": reason = checkGit(arguments)
        case "crontab": reason = checkCrontab(arguments)
        case "psql": return checkPSQL(words)
        default: reason = "\(name) isn't on the read-only list."
        }
        return reason.map { .failure(Refusal($0)) } ?? .success([])
    }

    /// `crontab -l`, optionally for another user (`-u <user>`).
    private static func checkCrontab(_ arguments: [String]) -> String? {
        var rest = arguments[...]
        var lists = false
        while let argument = rest.popFirst() {
            switch argument {
            case "-l": lists = true
            case "-u": guard rest.popFirst() != nil else { return "crontab -u needs a user." }
            default: return "Only crontab -l is allowed."
            }
        }
        return lists ? nil : "Only crontab -l is allowed."
    }

    private static let findActions: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"]

    private static func operands(_ arguments: [String]) -> [String] {
        arguments.filter { !$0.hasPrefix("-") }
    }

    /// Refuses short option clusters containing any of `letters` (`-fn` counts) and the long
    /// options, in any shortened form.
    private static func refuseShortFlags(_ arguments: [String], _ letters: String, long: [String], _ reason: String) -> String? {
        let refused = arguments.contains { argument in
            if argument.hasPrefix("--") { return isLongOption(argument, anyOf: long) }
            return argument.hasPrefix("-") && argument.dropFirst().contains(where: letters.contains)
        }
        return refused ? reason : nil
    }

    /// Whether `argument` names one of `options`. GNU tools (and git) take any unambiguous
    /// prefix of a long option, `--out` for `--output`, so every shortened form counts.
    static func isLongOption(_ argument: String, anyOf options: [String]) -> Bool {
        guard argument.hasPrefix("--") else { return false }
        let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        guard name.count > 2 else { return false }
        return options.contains { $0.hasPrefix(name) || name.hasPrefix($0) }
    }

    private static func checkSubcommand(_ arguments: [String], allowed: Set<String>, emptyAllowed: Bool = false) -> String? {
        guard let subcommand = operands(arguments).first else { return emptyAllowed ? nil : "A subcommand is missing." }
        return allowed.contains(subcommand) ? nil : "\(subcommand) isn't allowed; only \(allowed.sorted().joined(separator: ", "))."
    }

    private static func checkDocker(_ arguments: [String]) -> String? {
        if let reason = checkSubcommand(arguments, allowed: ["ps", "logs", "inspect", "images", "stats", "top", "version", "info"]) { return reason }
        switch operands(arguments).first {
        case "inspect": return checkDockerInspect(arguments)
        case "logs": return refuseShortFlags(arguments, "f", long: ["--follow"], "docker logs -f never ends; use --tail.")
        case "stats": return arguments.contains("--no-stream") ? nil : "Use docker stats --no-stream."
        default: return nil
        }
    }

    /// Fields `docker inspect --format` may print: not `.Config` (its `Env` holds secrets),
    /// nor the whole object.
    static let dockerInspectFields = #"^\.(State|Name|Id|Image|Created|RestartCount|Platform|NetworkSettings|HostConfig\.RestartPolicy|Mounts)\b"#

    /// `docker inspect` only with `--format` / `-f` templates over the fields above.
    private static func checkDockerInspect(_ arguments: [String]) -> String? {
        let refusal = "docker inspect prints the container's environment (secrets); use --format '{{.State.Status}}' and the like (State, Name, Id, Image, Created, RestartCount, NetworkSettings, Mounts)."
        var templates: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            if argument == "-f" || argument == "--format" {
                guard let template = rest.popFirst() else { return refusal }
                templates.append(template)
            } else if argument.hasPrefix("--format=") {
                templates.append(String(argument.dropFirst("--format=".count)))
            } else if argument.hasPrefix("-f"), argument.count > 2 {
                templates.append(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("-") {
                return refusal
            }
        }
        guard !templates.isEmpty else { return refusal }
        for template in templates {
            let actions = template.matches(of: /\{\{(.*?)\}\}/).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
            guard !actions.isEmpty, actions.allSatisfy({ $0.range(of: dockerInspectFields, options: .regularExpression) != nil }) else { return refusal }
        }
        return nil
    }

    private static func checkGit(_ arguments: [String]) -> String? {
        var rest = arguments[...]
        // Options before the subcommand: only -C <dir> and --no-pager (-c would set config).
        while let argument = rest.first, argument.hasPrefix("-") {
            rest = rest.dropFirst()
            if argument == "-C" { rest = rest.dropFirst() } else if argument != "--no-pager" { return "git \(argument) isn't allowed before the subcommand." }
        }
        guard let subcommand = rest.popFirst() else { return "A git subcommand is missing." }
        let options = Array(rest)
        if options.contains(where: { isLongOption($0, anyOf: ["--output"]) }) { return "git --output writes a file." }
        switch subcommand {
        case "log", "status", "show", "diff", "rev-parse", "describe", "shortlog", "blame", "ls-files":
            return nil
        case "remote":
            return options.allSatisfy { $0 == "-v" } ? nil : "Only git remote -v is allowed."
        case "branch":
            return options.allSatisfy { ["-a", "-r", "-v", "-vv", "--list", "--show-current"].contains($0) } ? nil : "Only listing branches is allowed."
        case "tag":
            return options.allSatisfy { ["-l", "--list"].contains($0) } ? nil : "Only listing tags is allowed."
        default:
            return "git \(subcommand) isn't allowed."
        }
    }

    // MARK: psql

    /// psql options that take a value, and those that don't, by short letter and long name.
    /// Anything else is refused: `-o`/`-f` touch files, `-P`/`-v` set a pager or variables,
    /// and psql takes shortened long options, so only the exact names below pass.
    private static let psqlValueOptions: [Character: String] = [
        "c": "--command", "d": "--dbname", "U": "--username", "h": "--host", "p": "--port",
        "F": "--field-separator", "R": "--record-separator",
    ]
    private static let psqlFlags: [Character: String] = [
        "l": "--list", "A": "--no-align", "t": "--tuples-only", "x": "--expanded", "X": "--no-psqlrc",
        "q": "--quiet", "w": "--no-password",
    ]

    /// `psql … -c "<query>"` with read-only queries, or `psql -l`. Returns where to insert
    /// the read-only session setting.
    private static func checkPSQL(_ words: [Word]) -> Result<[String.Index], Refusal> {
        var queries: [String] = []
        var lists = false
        var index = 1
        let allowed = "Only -c \"SELECT …\" with -d, -U, -h, -p, -A, -t, -x, -q, -X, -w, -F, -R or -l is allowed."
        func value(for option: String) throws -> String {
            guard index < words.count else { throw Refusal("psql \(option) needs a value.") }
            index += 1
            return words[index - 1].text
        }
        do {
            while index < words.count {
                let argument = words[index].text
                index += 1
                if argument.hasPrefix("--") {
                    let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                    if let letter = psqlValueOptions.first(where: { $0.value == parts[0] })?.key {
                        let given = parts.count == 2 ? parts[1] : try value(for: parts[0])
                        if letter == "c" { queries.append(given) }
                    } else if let letter = psqlFlags.first(where: { $0.value == parts[0] })?.key, parts.count == 1 {
                        if letter == "l" { lists = true }
                    } else {
                        return .failure(Refusal("psql \(parts[0]) isn't allowed. \(allowed)"))
                    }
                } else if argument.hasPrefix("-"), argument.count > 1 {
                    // A cluster such as -qAt or -qc'…': flags, then at most one option with its value.
                    var letters = Substring(argument.dropFirst())
                    while let letter = letters.popFirst() {
                        if psqlFlags[letter] != nil {
                            if letter == "l" { lists = true }
                        } else if psqlValueOptions[letter] != nil {
                            let given = letters.isEmpty ? try value(for: "-\(letter)") : String(letters)
                            letters = ""
                            if letter == "c" { queries.append(given) }
                        } else {
                            return .failure(Refusal("psql -\(letter) isn't allowed. \(allowed)"))
                        }
                    }
                }
                // Other words are the database and user names.
            }
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal("The psql command couldn't be read."))
        }
        if queries.isEmpty {
            return lists ? .success([]) : .failure(Refusal("Pass the query with psql -c \"SELECT …\"."))
        }
        for query in queries {
            if let reason = sqlRefusal(query) { return .failure(Refusal(reason)) }
        }
        return .success([words[0].end])
    }

    private static let sqlStarts: Set<String> = ["select", "with", "show", "explain", "table", "values"]

    private static let sqlWriteWords = #"\b(insert|update|delete|merge|truncate|drop|alter|create|grant|revoke|copy|vacuum|analyze|analyse|reindex|cluster|lock|call|do|set|reset|begin|start|commit|rollback|savepoint|release|notify|listen|unlisten|prepare|execute|deallocate|discard|refresh|import|load|checkpoint|into)\b"#

    /// Functions that change the server, read its files, or run SQL given as a string (which
    /// the checks here can't see into, since string literals are blanked first).
    private static let sqlWriteFunctions = #"\b(pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_rotate_logfile|pg_switch_wal|pg_promote|set_config|lo_\w+|dblink\w*|pg_read_file|pg_read_binary_file|pg_ls_dir|pg_sleep\w*|nextval|setval|pg_advisory\w*|pg_logical_emit_message|pg_create\w*|pg_drop\w*|pg_replication\w*|pg_file_\w+|pg_stat_reset\w*|pg_notify|pg_log_backend_memory_contexts|pg_import_system_collations|query_to_xml\w*|cursor_to_xml\w*)\s*\("#

    static func sqlRefusal(_ query: String) -> String? {
        var sql = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while sql.hasSuffix(";") { sql = String(sql.dropLast()).trimmingCharacters(in: .whitespaces) }
        if sql.contains("\\") { return "psql backslash commands aren't allowed." }
        if sql.contains("$$") { return "Dollar-quoted SQL isn't allowed." }
        // Literals can't hide statements; drop them before looking at the words.
        let bare = sql.lowercased().replacingOccurrences(of: #"'([^']|'')*'"#, with: "''", options: .regularExpression)
        if bare.contains(";") { return "Run one SQL statement at a time." }
        // A quoted name ("pg_terminate_backend"(…)) would get past the function list.
        if bare.range(of: #""[^"]*"\s*\("#, options: .regularExpression) != nil {
            return "Calling a function by a quoted name isn't allowed."
        }
        let firstWord = bare.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "\t" }).first.map(String.init) ?? ""
        guard sqlStarts.contains(firstWord) else { return "Only SELECT, WITH, SHOW, EXPLAIN, TABLE and VALUES queries are allowed." }
        if let match = bare.range(of: sqlWriteWords, options: .regularExpression) {
            return "The query uses \(bare[match].uppercased()), which can change data."
        }
        if bare.range(of: sqlWriteFunctions, options: .regularExpression) != nil {
            return "The query calls a function that changes the server or its data."
        }
        return nil
    }

    // MARK: Lexing

    struct Word {
        var text = ""
        var quoted = false
        /// Just past the word's last character in the original command.
        var end: String.Index
    }

    struct Refusal: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// Splits a command into pipeline / list segments of words, the way `sh` reads it, and
    /// refuses everything beyond words, pipes, `&&`, `||`, `;` and redirections to /dev/null.
    struct Lexer {
        private let text: String
        private var index: String.Index
        private var segments_: [[Word]] = [[]]
        private var word: Word?

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        mutating func segments() throws -> [[Word]] {
            while index < text.endIndex {
                let character = text[index]
                switch character {
                case " ", "\t":
                    finishWord()
                    advance()
                case "'":
                    advance()
                    guard let close = text[index...].firstIndex(of: "'") else { throw Refusal("A quote is never closed.") }
                    append(String(text[index..<close]), quoted: true)
                    index = text.index(after: close)
                case "\"":
                    advance()
                    try readDoubleQuoted()
                case "\\":
                    advance()
                    guard index < text.endIndex else { throw Refusal("The command ends with a backslash.") }
                    append(String(text[index]), quoted: true)
                    advance()
                case "`":
                    throw Refusal("Command substitution isn't allowed.")
                case "$":
                    if next == "(" { throw Refusal("Command substitution isn't allowed.") }
                    append("$")
                    advance()
                case "|":
                    finishWord()
                    advance()
                    if text[index...].first == "&" { throw Refusal("|& isn't allowed.") }
                    if text[index...].first == "|" { advance() }
                    try separate()
                case "&":
                    finishWord()
                    advance()
                    guard text[index...].first == "&" else { throw Refusal("Running in the background isn't allowed.") }
                    advance()
                    try separate()
                case ";":
                    finishWord()
                    advance()
                    try separate()
                case ">":
                    try readRedirection()
                case "<":
                    throw Refusal("Reading input from files or here-documents isn't allowed.")
                case "(", ")":
                    throw Refusal("Subshells aren't allowed.")
                case "#" where word == nil:
                    throw Refusal("Comments aren't allowed.")
                default:
                    append(String(character))
                    advance()
                }
            }
            finishWord()
            if segments_.contains(where: \.isEmpty) { throw Refusal("A command is missing between operators.") }
            return segments_
        }

        private var next: Character? {
            let after = text.index(after: index)
            return after < text.endIndex ? text[after] : nil
        }

        private mutating func advance() {
            index = text.index(after: index)
        }

        private mutating func append(_ string: String, quoted: Bool = false) {
            if word == nil { word = Word(end: index) }
            word?.text += string
            if quoted { word?.quoted = true }
        }

        private mutating func finishWord() {
            guard var finished = word else { return }
            finished.end = index
            segments_[segments_.count - 1].append(finished)
            word = nil
        }

        private mutating func separate() throws {
            finishWord()
            guard segments_.last?.isEmpty == false else { throw Refusal("A command is missing between operators.") }
            segments_.append([])
        }

        private mutating func readDoubleQuoted() throws {
            if word == nil { word = Word(end: index) }
            word?.quoted = true
            while index < text.endIndex {
                let character = text[index]
                switch character {
                case "\"":
                    advance()
                    return
                case "\\":
                    advance()
                    guard index < text.endIndex else { throw Refusal("A quote is never closed.") }
                    word?.text.append(text[index])
                    advance()
                case "`":
                    throw Refusal("Command substitution isn't allowed.")
                case "$" where next == "(":
                    throw Refusal("Command substitution isn't allowed.")
                default:
                    word?.text.append(character)
                    advance()
                }
            }
            throw Refusal("A quote is never closed.")
        }

        /// `>`, `>>`, `2>`, `>&2`, `2>&1`: only to /dev/null or another output stream.
        private mutating func readRedirection() throws {
            // A file-descriptor number right before `>` belongs to the redirection.
            if let pending = word, !pending.quoted, pending.text.allSatisfy(\.isNumber) { word = nil } else { finishWord() }
            advance()
            if text[index...].first == ">" { advance() }
            if text[index...].first == "&" {
                advance()
                let digits = text[index...].prefix(while: \.isNumber)
                guard !digits.isEmpty else { throw Refusal("Writing to files isn't allowed.") }
                index = digits.endIndex
                return
            }
            while text[index...].first == " " { advance() }
            let target = text[index...].prefix(while: { !" \t|&;<>()".contains($0) })
            index = target.endIndex
            guard target == "/dev/null" else { throw Refusal("Writing to files isn't allowed (only > /dev/null).") }
        }
    }
}
