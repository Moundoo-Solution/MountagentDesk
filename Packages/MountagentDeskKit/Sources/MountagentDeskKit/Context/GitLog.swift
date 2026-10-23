import Foundation

/// Commit history for the Git panel's History tab.
public enum GitLog {

    public struct Commit: Identifiable, Hashable, Sendable {
        public var sha: String
        public var parents: [String]
        public var author: String
        public var email: String
        public var date: Date
        /// Branches and tags pointing here: `main`, `origin/main`, `v1.0`.
        public var refs: [String]
        public var subject: String
        public var id: String { sha }
        public var shortSHA: String { GitLog.short(sha) }
        public var isMerge: Bool { parents.count > 1 }
        public var references: References { References(subject: subject) }
    }

    /// What a subject points at: "Merge pull request #99 from …", "(task 1234)",
    /// "CD-005-U8: …" (the work item's code, from the subject or the merged branch).
    public struct References: Hashable, Sendable {
        public var pullRequest: Int?
        public var tasks: [String]
        public var code: String?
        /// The code as written, with its story suffix: "CD-005-U8".
        public var label: String?

        public init(subject: String) {
            pullRequest = (subject.firstMatch(of: /(?:pull request |\(|\s)#(\d+)\b/)?.1).flatMap { Int($0) }
            tasks = subject.matches(of: /\b(?i:task|ticket)s?\s+#?(\d{3,})/).map { String($0.1) }
            let match = subject.firstMatch(of: /\b([A-Z]{2,5}-\d{2,4}(?:\.\d+)?)(?:-U\d+)?\b/)
            code = match.map { String($0.1) }
            label = match.map { String($0.0) }
        }
    }

    /// The abbreviated hash shown everywhere in the app.
    public static func short(_ sha: String) -> String { String(sha.prefix(8)) }

    private static let field = "\u{1F}"
    private static let record = "\u{1E}"

    /// `branch` (or any revision) and its ancestors, newest first.
    /// With `authors` (emails), only their commits; git ORs the `--author` patterns, and
    /// `--fixed-strings` keeps an email's dots and pluses literal; case doesn't matter.
    public static func commits(in root: URL, branch: String = "HEAD", limit: Int = 500, authors: [String] = []) -> [Commit] {
        var arguments = ["log", "--date-order", "--format=%H\(field)%P\(field)%an\(field)%ae\(field)%at\(field)%D\(field)%s\(record)",
                         "-n", String(limit)]
        if !authors.isEmpty {
            arguments += ["--fixed-strings", "--regexp-ignore-case"]
            arguments += authors.map { "--author=<\($0)>" }
        }
        arguments += [branch, "--"]
        guard let output = try? GitInspector(root: root).git(arguments) else { return [] }
        return parse(output)
    }

    /// Someone who committed on a branch, and how often.
    public struct Author: Identifiable, Hashable, Sendable {
        public var name: String
        public var email: String
        public var commits: Int
        public var id: String { email.lowercased() }
    }

    /// The branch's committers among its latest `limit` commits, most commits first. One
    /// entry per email, named as most of its commits are.
    public static func authors(in root: URL, branch: String = "HEAD", limit: Int = 5000) -> [Author] {
        guard let output = try? GitInspector(root: root).git(["shortlog", "-sne", "--max-count=\(limit)", branch, "--"]) else { return [] }
        return parseAuthors(output)
    }

    /// `git shortlog -sne` lines: `   42\tName <email>`.
    static func parseAuthors(_ output: String) -> [Author] {
        var byEmail: [String: Author] = [:]
        for line in output.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: /^\s*(\d+)\t(.*?)\s*<([^>]*)>\s*$/), let count = Int(match.1) else { continue }
            let email = String(match.3)
            let key = email.lowercased()
            if var known = byEmail[key] {
                // shortlog lists the busier name first; keep it, add the counts.
                known.commits += count
                byEmail[key] = known
            } else {
                byEmail[key] = Author(name: String(match.2), email: email, commits: count)
            }
        }
        return byEmail.values.sorted { ($0.commits, $1.name) > ($1.commits, $0.name) }
    }

    static func parse(_ output: String) -> [Commit] {
        output.components(separatedBy: record).compactMap { chunk in
            let parts = chunk.trimmingCharacters(in: .newlines).components(separatedBy: field)
            guard parts.count >= 7, !parts[0].isEmpty else { return nil }
            return Commit(
                sha: parts[0],
                parents: parts[1].split(separator: " ").map(String.init),
                author: parts[2],
                email: parts[3],
                date: Date(timeIntervalSince1970: TimeInterval(parts[4]) ?? 0),
                refs: parseRefs(parts[5]),
                subject: parts[6...].joined(separator: field)
            )
        }
    }

    /// `HEAD -> main, origin/main, tag: v1.0, origin/HEAD` → `main, origin/main, v1.0`.
    static func parseRefs(_ decoration: String) -> [String] {
        decoration.split(separator: ",").compactMap { raw in
            var item = raw.trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("HEAD -> ") { item.removeFirst("HEAD -> ".count) }
            if item.hasPrefix("tag: ") { item.removeFirst("tag: ".count) }
            return item.isEmpty || item == "HEAD" || item.hasSuffix("/HEAD") ? nil : item
        }
    }

    // MARK: Commit details

    public struct Detail: Sendable {
        public var message: String
        public var files: [GitInspector.FileChange]
    }

    /// Full message and files changed (against the first parent for merges).
    public static func detail(of commit: Commit, in root: URL) -> Detail {
        let git = GitInspector(root: root)
        let message = (try? git.git(["show", "-s", "--format=%B", commit.sha]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? commit.subject
        let numstat: String
        if let parent = commit.parents.first {
            numstat = (try? git.git(["diff", "--numstat", "-M", parent, commit.sha])) ?? ""
        } else {
            numstat = (try? git.git(["show", "--format=", "--numstat", "-M", commit.sha])) ?? ""
        }
        let files = numstat.split(separator: "\n").compactMap { line -> GitInspector.FileChange? in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            let path = GitInspector.renamedTarget(parts[2])
            let additions = Int(parts[0]) ?? 0
            let deletions = Int(parts[1]) ?? 0
            let status: GitInspector.FileChange.Status = parts[2].contains("=>") ? .renamed : additions > 0 && deletions == 0 ? .added : .modified
            return GitInspector.FileChange(path: path, additions: additions, deletions: deletions, status: status, isBinary: parts[0] == "-")
        }
        return Detail(message: message, files: files)
    }

    public static func diff(of commit: Commit, file: String, in root: URL) -> String {
        let git = GitInspector(root: root)
        if let parent = commit.parents.first {
            return (try? git.git(["diff", "-M", parent, commit.sha, "--", file])) ?? ""
        }
        return (try? git.git(["show", "--format=", commit.sha, "--", file])) ?? ""
    }
}
