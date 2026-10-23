import Foundation

/// Browser sign-in to GitHub through the official CLI (`gh auth login --web`), which keeps
/// several accounts at once. Mountagent Desk uses it to fill in an account's name and verified
/// email and to upload its SSH key; pushes themselves still go through that key.
public enum GitHubCLI {
    public struct Profile: Equatable, Sendable {
        public var login: String
        public var name: String?
        /// Primary verified email, or the account's no-reply address when none is public.
        public var email: String?
    }

    public static func locate() -> URL? {
        ExecutableLocator.find("gh")
    }

    /// Homebrew when it is there; otherwise the user installs from cli.github.com.
    public static var installCommand: String? {
        ExecutableLocator.find("brew").map { "\(Shell.quote($0.path)) install gh" }
    }

    /// Device-code sign-in in the browser, with the scopes needed to read emails and add keys.
    public static func loginCommand(gh: String = "gh") -> String {
        "\(gh) auth login --hostname github.com --git-protocol ssh --web --skip-ssh-key --scopes admin:public_key,user:email"
    }

    /// Accounts `gh` is signed in to on github.com.
    public static func accounts() -> [String] {
        guard let output = try? run(["auth", "status", "--hostname", "github.com"]) else { return [] }
        return parseAccounts(output)
    }

    /// "✓ Logged in to github.com account octocat-work (keyring)" → "octocat-work".
    static func parseAccounts(_ output: String) -> [String] {
        var seen: [String] = []
        for match in output.matches(of: /Logged in to [^\s]+ (?:account|as) ([A-Za-z0-9-]+)/) {
            let login = String(match.1)
            if !seen.contains(login) { seen.append(login) }
        }
        return seen
    }

    public static func profile(of login: String) -> Profile? {
        guard let token = token(for: login),
              let user = try? run(["api", "user"], token: token),
              let object = JSONLine.object(user)
        else { return nil }
        var profile = Profile(login: object["login"] as? String ?? login, name: object["name"] as? String, email: object["email"] as? String)
        if let emails = try? run(["api", "user/emails"], token: token) {
            profile.email = primaryEmail(from: emails) ?? profile.email
        }
        if profile.email == nil, let id = object["id"] as? Int {
            profile.email = "\(id)+\(profile.login)@users.noreply.github.com"
        }
        return profile
    }

    static func primaryEmail(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        let verified = list.filter { $0["verified"] as? Bool == true }
        return (verified.first { $0["primary"] as? Bool == true } ?? verified.first)?["email"] as? String
    }

    public enum KeyUpload: Equatable, Sendable {
        case added
        case alreadyThere
        case failed(String)
    }

    /// Adds a public key to the account unless it is already one of its keys.
    public static func uploadKey(publicKey: String, title: String, for login: String) -> KeyUpload {
        guard let token = token(for: login) else { return .failed("Sign in to \(login) with GitHub first.") }
        let body = publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        if let keys = try? run(["api", "user/keys"], token: token), keys.contains(body) {
            return .alreadyThere
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mountagent-\(UUID().uuidString).pub")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try publicKey.write(to: file, atomically: true, encoding: .utf8)
            try run(["ssh-key", "add", file.path, "--title", title], token: token)
            return .added
        } catch let failure as GitClient.Failure {
            return .failed("GitHub didn't accept the key: \(failure.message)")
        } catch {
            return .failed("Couldn't add the key: \(error.localizedDescription)")
        }
    }

    /// The account's token, handed to each `gh` call so requests act as that account
    /// whichever one `gh` currently treats as active.
    public static func token(for login: String) -> String? {
        let value = (try? run(["auth", "token", "--hostname", "github.com", "--user", login]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    // MARK: Pull requests

    public struct PullRequest: Equatable, Sendable {
        public var number: Int
        public var url: URL
        /// OPEN, MERGED or CLOSED.
        public var state: String
        public var isDraft: Bool
    }

    /// The repository's default branch on GitHub (what a pull request merges into).
    public static func defaultBranch(in repository: URL, token: String? = nil) -> String? {
        let name = (try? run(["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], token: token, in: repository))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// The pull request opened from `branch`, if there is one.
    public static func pullRequest(for branch: String, in repository: URL, token: String? = nil) -> PullRequest? {
        guard let json = try? run(["pr", "view", branch, "--json", "number,url,state,isDraft"], token: token, in: repository) else { return nil }
        return parsePullRequest(json)
    }

    static func parsePullRequest(_ json: String) -> PullRequest? {
        guard let object = JSONLine.object(jsonPart(json)), let number = object["number"] as? Int,
              let link = object["url"] as? String, let url = URL(string: link)
        else { return nil }
        return PullRequest(number: number, url: url, state: object["state"] as? String ?? "OPEN", isDraft: object["isDraft"] as? Bool ?? false)
    }

    /// Opens a pull request from `head` (already pushed) into `base`; returns its address.
    public static func createPullRequest(in repository: URL, head: String, base: String, title: String, body: String,
                                         draft: Bool, token: String? = nil) throws -> URL {
        var arguments = ["pr", "create", "--head", head, "--base", base, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        let output = try run(arguments, token: token, in: repository)
        guard let url = pullRequestURL(in: output) else {
            throw GitClient.Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return url
    }

    /// `gh pr create` prints the new pull request's address last.
    static func pullRequestURL(in output: String) -> URL? {
        output.split(whereSeparator: \.isNewline).reversed()
            .first { $0.hasPrefix("https://") && $0.contains("/pull/") }
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func jsonPart(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }

    @discardableResult
    private static func run(_ arguments: [String], token: String? = nil, in directory: URL? = nil) throws -> String {
        guard let gh = locate() else { throw GitClient.Failure(message: "The GitHub CLI (gh) isn't installed.") }
        let process = Process()
        process.executableURL = gh
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ExecutableLocator.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        if let token { environment["GH_TOKEN"] = token }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        // `auth status` exits non-zero when any host has a problem but still lists accounts.
        guard process.terminationStatus == 0 || arguments.starts(with: ["auth", "status"]) else {
            throw GitClient.Failure(message: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
