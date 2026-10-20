import Foundation

/// A git identity plus the SSH key that authenticates it, e.g. a work and a personal
/// GitHub account. Applied per repository, so every tool (agents, terminals, Cursor,
/// Sourcetree) commits and pushes as the same account.
public struct GitAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var name: String
    public var email: String
    /// Private key path; `nil` leaves authentication to the user's default SSH setup.
    public var sshKeyPath: String?
    /// The GitHub account signed in through the browser (`gh`), when there is one.
    public var githubLogin: String?

    public init(id: UUID = UUID(), label: String, name: String, email: String, sshKeyPath: String?, githubLogin: String? = nil) {
        self.id = id
        self.label = label
        self.name = name
        self.email = email
        self.sshKeyPath = sshKeyPath
        self.githubLogin = githubLogin
    }

    /// `ssh -i '<key>' -o IdentitiesOnly=yes`: without IdentitiesOnly, ssh offers the agent's
    /// other keys first and GitHub may sign in as the wrong account.
    public var sshCommand: String? {
        sshKeyPath.map { "ssh -i \(Shell.quote($0)) -o IdentitiesOnly=yes" }
    }
}

/// What a repository is set up to use, as git resolves it.
public struct GitIdentity: Equatable, Sendable {
    public var name: String?
    public var email: String?
    /// `core.sshCommand` set in this repository.
    public var sshCommand: String?
    /// Whether name/email come from the repository itself (not the global config).
    public var isLocal: Bool
    public var remoteURL: String?

    public var remoteIsHTTPS: Bool { remoteURL?.hasPrefix("https://") == true }
}

public struct GitRepository: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var isRepository: Bool {
        (try? git(["rev-parse", "--is-inside-work-tree"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func identity() -> GitIdentity {
        let localEmail = value(["config", "--local", "--get", "user.email"])
        return GitIdentity(
            name: value(["config", "--get", "user.name"]),
            email: value(["config", "--get", "user.email"]),
            sshCommand: value(["config", "--local", "--get", "core.sshCommand"]),
            isLocal: localEmail != nil,
            remoteURL: value(["remote", "get-url", "origin"])
        )
    }

    /// Writes the account into this repository's `.git/config`.
    public func apply(_ account: GitAccount) throws {
        try git(["config", "--local", "user.name", account.name])
        try git(["config", "--local", "user.email", account.email])
        if let command = account.sshCommand {
            try git(["config", "--local", "core.sshCommand", command])
        } else {
            _ = try? git(["config", "--local", "--unset", "core.sshCommand"])
        }
    }

    /// Removes Mountagent Desk's settings so the global config applies again.
    public func clearAccount() {
        for key in ["user.name", "user.email", "core.sshCommand"] {
            _ = try? git(["config", "--local", "--unset", key])
        }
    }

    /// Points `origin` at the SSH form of its HTTPS URL; returns the new URL.
    @discardableResult
    public func switchRemoteToSSH() throws -> String? {
        guard let url = value(["remote", "get-url", "origin"]), let ssh = Self.sshURL(fromHTTPS: url) else { return nil }
        try git(["remote", "set-url", "origin", ssh])
        return ssh
    }

    /// Whether a fetch, pull or push failed because an HTTPS remote had no usable sign-in.
    /// GitHub answers "Repository not found" rather than 401 for private repositories,
    /// and with prompts disabled git cannot ask for a username.
    public static func isHTTPSSignInFailure(_ message: String) -> Bool {
        guard message.contains("https://") else { return false }
        return ["Repository not found", "Authentication failed", "could not read Username",
                "terminal prompts disabled", "The requested URL returned error: 403"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// The repository's web page from an HTTPS or SSH remote:
    /// `git@github.com:owner/repo.git` → `https://github.com/owner/repo`.
    public static func webURL(fromRemote remote: String) -> URL? {
        var host: String
        var path: String
        if let match = remote.wholeMatch(of: /(?:ssh:\/\/)?[^@\/]+@([^:\/]+)[:\/](.+)/) {
            host = String(match.1)
            path = String(match.2)
        } else if let components = URLComponents(string: remote), components.scheme == "https", let componentHost = components.host {
            host = componentHost
            path = components.path
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.split(separator: "/").count >= 2 else { return nil }
        host = host.lowercased()
        return URL(string: "https://\(host)/\(path)")
    }

    /// `https://github.com/owner/repo(.git)` → `git@github.com:owner/repo.git`.
    public static func sshURL(fromHTTPS url: String) -> String? {
        guard let components = URLComponents(string: url), components.scheme == "https",
              let host = components.host
        else { return nil }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.split(separator: "/").count >= 2 else { return nil }
        if !path.hasSuffix(".git") { path += ".git" }
        return "git@\(host):\(path)"
    }

    private func value(_ arguments: [String]) -> String? {
        guard let output = try? git(arguments) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        try GitInspector(root: root).git(arguments)
    }
}

/// SSH keys in `~/.ssh`, and the commands that create and test them.
public enum SSHKeys {
    public struct Key: Identifiable, Hashable, Sendable {
        public var privatePath: String
        public var publicKey: String
        /// The key's comment, usually the email it was made for.
        public var comment: String
        public var id: String { privatePath }
        public var name: String { (privatePath as NSString).lastPathComponent }
    }

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Key pairs (a `.pub` file next to its private key).
    public static func list(in directory: URL = directory) -> [Key] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "pub" }
            .compactMap { pub -> Key? in
                let privatePath = pub.deletingPathExtension().path
                guard FileManager.default.fileExists(atPath: privatePath),
                      let text = try? String(contentsOf: pub, encoding: .utf8)
                else { return nil }
                let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
                return Key(privatePath: privatePath, publicKey: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           comment: parts.count > 2 ? String(parts[2]) : "")
            }
            .sorted { $0.name < $1.name }
    }

    /// Creates an ed25519 key without a passphrase (agents can't type one).
    public static func generate(named name: String, comment: String, in directory: URL = directory) throws -> Key {
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let path = directory.appendingPathComponent(safe).path
        guard !FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", "ed25519", "-C", comment, "-f", path, "-N", "", "-q"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        // Compare by name: the listing may spell the folder through /private (symlinks).
        guard process.terminationStatus == 0, let key = list(in: directory).first(where: { $0.name == safe }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return key
    }

    public enum TestResult: Equatable, Sendable {
        case authenticated(username: String)
        case failed(String)
    }

    /// `ssh -T git@github.com` with only this key; GitHub answers "Hi <user>! …".
    public static func testGitHub(keyPath: String?, host: String = "github.com") -> TestResult {
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10"]
        if let keyPath { arguments += ["-i", keyPath, "-o", "IdentitiesOnly=yes"] }
        arguments.append("git@\(host)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
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
        return parseTest(String(decoding: data, as: UTF8.self))
    }

    static func parseTest(_ output: String) -> TestResult {
        if let match = output.firstMatch(of: /Hi ([^!]+)! You've successfully authenticated/) {
            return .authenticated(username: String(match.1))
        }
        let line = output.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return .failed(line.map(String.init) ?? "No answer from GitHub.")
    }
}

/// Builds the first account from what the machine already uses (global git identity and
/// the key `~/.ssh/config` gives github.com), so existing setups appear without typing.
public enum GitAccountImport {
    public static func current(sshConfig: URL = SSHKeys.directory.appendingPathComponent("config")) -> GitAccount? {
        let home = GitInspector(root: FileManager.default.homeDirectoryForCurrentUser)
        func global(_ key: String) -> String? {
            let value = (try? home.git(["config", "--global", "--get", key]))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        guard let name = global("user.name"), let email = global("user.email") else { return nil }
        return GitAccount(label: name, name: name, email: email, sshKeyPath: githubKey(in: sshConfig))
    }

    /// The `IdentityFile` of the `Host github.com` block in an ssh config.
    static func githubKey(in config: URL) -> String? {
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        var inGitHub = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "host":
                inGitHub = parts[1].split(separator: " ").contains { $0 == "github.com" }
            case "identityfile" where inGitHub:
                return (parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as NSString).expandingTildeInPath
            default:
                break
            }
        }
        return nil
    }
}
