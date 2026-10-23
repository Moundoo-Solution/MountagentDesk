import Foundation

/// What a server is for, read from its name: "Acme Live" is live, "Acme UAT" is UAT.
/// Live servers ask before connecting and show their terminals in red.
public enum ServerEnvironment: String, CaseIterable, Sendable {
    case live, uat, test, dev

    /// `acme-live`, `Prod DB` → live; `acme-uat`, `staging` → UAT; `dev` → dev; else test.
    public static func guess(from name: String) -> ServerEnvironment {
        let lower = name.lowercased()
        if ["live", "prod"].contains(where: lower.contains) { return .live }
        if ["uat", "staging", "stage"].contains(where: lower.contains) { return .uat }
        if lower.contains("dev") { return .dev }
        return .test
    }
}

/// A machine the user reaches over SSH. Linked to projects like git accounts are; signs in
/// with a shared `ServerCredential` (as Termius hosts pick a keychain entry). Agents may
/// only read it, and only after the user turns that on (`aiReadAccess`).
public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// A host name, an IP or a `Host` alias from `~/.ssh/config` (whose settings then apply).
    public var host: String
    /// Overrides the credential's user name.
    public var user: String?
    public var port: Int?
    public var credentialID: UUID?
    /// The server's own password is in the login keychain (it wins over the credential's).
    public var passwordSaved: Bool
    /// Agents may run read-only commands here through `mountagent-server`. Off by default.
    public var aiReadAccess: Bool
    /// Users agents may `sudo -u` to here (`root` for plain sudo). None by default: a sudo
    /// rule would let a read reach files and databases the SSH user can't.
    public var agentSudoUsers: [String] = []

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        credentialID: UUID? = nil,
        passwordSaved: Bool = false,
        aiReadAccess: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.credentialID = credentialID
        self.passwordSaved = passwordSaved
        self.aiReadAccess = aiReadAccess
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, user, port, credentialID, passwordSaved, aiReadAccess, agentSudoUsers
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID)
        passwordSaved = try container.decodeIfPresent(Bool.self, forKey: .passwordSaved) ?? false
        aiReadAccess = try container.decodeIfPresent(Bool.self, forKey: .aiReadAccess) ?? false
        agentSudoUsers = try container.decodeIfPresent([String].self, forKey: .agentSudoUsers) ?? []
    }

    public var environment: ServerEnvironment { .guess(from: name) }

    /// The keychain account of the server's own password.
    public var passwordAccount: String { "server-" + id.uuidString }

    /// A name an agent can type: lower case, no spaces.
    public var handle: String {
        let lowered = name.lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? host : trimmed
    }

    public func login(with credentials: [ServerCredential]) -> SSHLogin {
        SSHLogin(server: self, credential: credentials.first { $0.id == credentialID })
    }
}

/// A reusable sign-in, like an entry in Termius's keychain: a user name with a key, a
/// password, or both. The password itself is in the login keychain (`ServerPasswords`).
public struct ServerCredential: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var user: String?
    /// Private key path; `nil` leaves keys to the user's SSH setup.
    public var keyPath: String?
    public var hasPassword: Bool

    /// The keychain account of the credential's password.
    public var passwordAccount: String { id.uuidString }

    public init(id: UUID = UUID(), name: String, user: String? = nil, keyPath: String? = nil, hasPassword: Bool = false) {
        self.id = id
        self.name = name
        self.user = user
        self.keyPath = keyPath
        self.hasPassword = hasPassword
    }

    /// "ubuntu · key + password".
    public var summary: String {
        let kind = [keyPath.map { _ in "key" }, hasPassword ? "password" : nil].compactMap(\.self).joined(separator: " + ")
        return [user, kind.isEmpty ? nil : kind].compactMap(\.self).joined(separator: " · ")
    }

    /// Servers saved before credentials kept a key path and a password of their own. Each
    /// becomes a credential with the server's id, so its keychain password still matches.
    public static func migrate(_ data: Data?, servers: inout [Server]) -> [ServerCredential] {
        struct Legacy: Decodable {
            var id: UUID
            var name: String
            var user: String?
            var keyPath: String?
            var hasPassword: Bool?
            var credentialID: UUID?
        }
        guard let data, let legacy = try? JSONDecoder().decode([Legacy].self, from: data) else { return [] }
        var made: [ServerCredential] = []
        for old in legacy where old.credentialID == nil && (old.keyPath != nil || old.hasPassword == true) {
            made.append(ServerCredential(id: old.id, name: old.name, user: old.user, keyPath: old.keyPath, hasPassword: old.hasPassword ?? false))
            if let index = servers.firstIndex(where: { $0.id == old.id }) { servers[index].credentialID = old.id }
        }
        return made
    }
}

/// A server with its credential: the ssh command lines to reach it.
public struct SSHLogin: Sendable {
    public let server: Server
    public let credential: ServerCredential?

    public init(server: Server, credential: ServerCredential?) {
        self.server = server
        self.credential = credential
    }

    /// The server's own user name, else the credential's; `nil` leaves it to the SSH config.
    public var user: String? {
        [server.user, credential?.user].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// `user@host`, or the bare host when the user comes from the SSH config.
    public var destination: String {
        user.map { "\($0)@\(server.host)" } ?? server.host
    }

    /// The keychain account to answer ssh's password prompt from: the server's own
    /// password first, then the credential's.
    var passwordAccount: String? {
        if server.passwordSaved { return server.passwordAccount }
        if let credential, credential.hasPassword { return credential.passwordAccount }
        return nil
    }

    var usesPassword: Bool { passwordAccount != nil }

    /// The saved password ssh will ask for, from the keychain (the app's own process only).
    public func savedPassword() -> String? {
        passwordAccount.flatMap(ServerPasswords.password(account:))
    }

    /// Arguments for an agent's read-only command, which the app runs itself (`ServerRun`).
    /// ~/.ssh/config isn't read (`-F /dev/null`): a ProxyCommand, LocalCommand or `Match exec`
    /// there would run beside ssh while it is asked for the password. An alias's host name,
    /// user, port and key come from `config`, parsed here, and only hosts already in
    /// known_hosts are accepted, so a changed host name can't lead elsewhere unnoticed.
    public func agentArguments(_ command: String, config: SSHConfigImport.Entry?) -> [String] {
        var arguments = ["-F", "/dev/null", "-T", "-n", "-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=yes"]
        arguments += usesPassword ? ["-o", "NumberOfPasswordPrompts=1"] : ["-o", "BatchMode=yes"]
        if let port = server.port ?? config?.port { arguments += ["-p", String(port)] }
        if let key = credential?.keyPath ?? config?.identityFile, !key.isEmpty {
            arguments += ["-i", (key as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        let host = config?.hostName ?? server.host
        arguments.append((user ?? config?.user).map { "\($0)@\(host)" } ?? host)
        arguments.append(command)
        return arguments
    }

    /// Port and key options; the destination goes after them.
    public var sshOptions: [String] {
        var options: [String] = []
        if let port = server.port { options += ["-p", String(port)] }
        if let keyPath = credential?.keyPath, !keyPath.isEmpty { options += ["-i", keyPath, "-o", "IdentitiesOnly=yes"] }
        return options
    }

    /// Arguments for an interactive session in a terminal. A host not yet in known_hosts is
    /// asked about in the terminal, with its fingerprint, rather than trusted silently.
    public var interactiveArguments: [String] {
        ["-o", "ServerAliveInterval=30"]
            + (usesPassword ? ["-o", "NumberOfPasswordPrompts=1"] : []) + sshOptions + [destination]
    }

    /// Arguments that run one command and return, without ever prompting a person (a saved
    /// password comes from `askpassEnvironment`).
    public func commandArguments(_ command: String) -> [String] {
        let unattended = usesPassword ? ["-o", "NumberOfPasswordPrompts=1"] : ["-o", "BatchMode=yes"]
        return ["-T"] + unattended + ["-o", "ConnectTimeout=15", "-o", "StrictHostKeyChecking=accept-new"]
            + sshOptions + [destination, command]
    }

    /// Lets ssh read the saved password through `askpass` (the `mountagent-server`
    /// script) instead of asking; empty without one.
    public func askpassEnvironment(askpass: URL) -> [String: String] {
        guard let passwordAccount else { return [:] }
        return [
            "SSH_ASKPASS": askpass.path,
            "SSH_ASKPASS_REQUIRE": "force",
            ServerPasswords.askpassVariable: passwordAccount,
        ]
    }

    public enum TestResult: Equatable, Sendable {
        case connected
        case failed(String)
    }

    /// Signs in without a prompt (using the saved password, if any) and runs `true`.
    public func testConnection(askpass: URL) -> TestResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = commandArguments("true")
        process.environment = ProcessInfo.processInfo.environment.merging(askpassEnvironment(askpass: askpass)) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .connected }
        let text = String(decoding: data, as: UTF8.self)
        let line = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return .failed(line.map(String.init) ?? "ssh exited with status \(process.terminationStatus).")
    }
}

/// Private keys picked from anywhere (an AWS `.pem`), kept where ssh accepts them.
public enum ServerKeys {
    public static var directory: URL {
        SSHKeys.directory.appendingPathComponent("mountagent", isDirectory: true)
    }

    /// Copies a key file into `~/.ssh/mountagent/` readable only by the user (ssh refuses
    /// keys others can read); returns the copy's path.
    public static func importKey(from source: URL, into directory: URL = directory) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var target = directory.appendingPathComponent(source.lastPathComponent)
        if target.standardizedFileURL.path == source.standardizedFileURL.path { return target.path }
        var counter = 2
        while fileManager.fileExists(atPath: target.path) {
            if fileManager.contentsEqual(atPath: target.path, andPath: source.path) { return target.path }
            target = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(counter).\(source.pathExtension)")
            counter += 1
        }
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target.path
    }
}

/// A command the Servers panel can type into a terminal (never run without Return).
public struct ServerSnippet: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var command: String

    public init(id: UUID = UUID(), title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }

    /// Everyday Linux server chores. Words in capitals (SERVICE, a log's path) are meant to
    /// be edited before Return; app-specific commands go in the user's own list.
    public static let common: [ServerSnippet] = [
        ServerSnippet(title: "System log, last 200 lines", command: "journalctl -n 200 --no-pager"),
        ServerSnippet(title: "Errors in the system log", command: "journalctl -p err -n 100 --no-pager"),
        ServerSnippet(title: "A log file, last 200 lines", command: "tail -n 200 /var/log/APP.log"),
        ServerSnippet(title: "Service status", command: "systemctl status SERVICE --no-pager"),
        ServerSnippet(title: "Restart a service", command: "sudo systemctl restart SERVICE"),
        ServerSnippet(title: "Disk space", command: "df -h"),
        ServerSnippet(title: "Memory", command: "free -h"),
        ServerSnippet(title: "Busiest processes", command: "ps aux --sort=-%mem | head -n 15"),
        ServerSnippet(title: "Listening ports", command: "ss -tlnp"),
        ServerSnippet(title: "PostgreSQL databases", command: "sudo -u postgres psql -l"),
        ServerSnippet(title: "PostgreSQL running queries", command: "sudo -u postgres psql -c \"SELECT pid, datname, state, now() - query_start AS age, left(query, 80) FROM pg_stat_activity WHERE state <> 'idle' ORDER BY age DESC\""),
    ]
}

/// Hosts from `~/.ssh/config`, so servers the user already reaches appear without typing.
public enum SSHConfigImport {
    public struct Entry: Identifiable, Hashable, Sendable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var port: Int?
        public var identityFile: String?
        public var id: String { alias }

        /// Keeps the alias as the host, so the config's other settings (ProxyJump…) still apply.
        public var server: Server {
            Server(name: alias, host: alias)
        }

        public var summary: String {
            let host = hostName ?? alias
            return (user.map { "\($0)@" } ?? "") + host + (port.map { ":\($0)" } ?? "")
        }
    }

    public static var defaultConfig: URL { SSHKeys.directory.appendingPathComponent("config") }

    /// Concrete `Host` names (no wildcards), in file order.
    public static func entries(in config: URL = defaultConfig) -> [Entry] {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [Int] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for alias in value.split(separator: " ").map(String.init)
                where !alias.contains(where: { "*?!".contains($0) }) && !entries.contains(where: { $0.alias == alias }) {
                    entries.append(Entry(alias: alias))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "hostname":
                for index in current { entries[index].hostName = value }
            case "user":
                for index in current { entries[index].user = value }
            case "port":
                for index in current { entries[index].port = Int(value) }
            case "identityfile":
                for index in current where entries[index].identityFile == nil {
                    entries[index].identityFile = (value as NSString).expandingTildeInPath
                }
            default:
                break
            }
        }
        return entries
    }
}
