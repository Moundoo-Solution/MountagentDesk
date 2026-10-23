import Foundation

/// Read and write operations on one repository, GitHub Desktop style. Every command runs
/// without a terminal (`GIT_TERMINAL_PROMPT=0`), so a missing credential fails with a
/// message instead of hanging, and editors are skipped (`GIT_EDITOR=true`).
public struct GitClient: Sendable {
    public let root: URL
    /// Off for the app's own bookkeeping (checkpoints, worktrees): a hook there would run
    /// code the agent planted, uninvited.
    let runsHooks: Bool

    public init(root: URL) {
        self.init(root: root, runsHooks: true)
    }

    init(root: URL, runsHooks: Bool) {
        self.root = root
        self.runsHooks = runsHooks
    }

    // MARK: Status

    public struct FileStatus: Identifiable, Hashable, Sendable {
        public enum Kind: String, Sendable { case modified, added, deleted, renamed, untracked, conflicted }
        public var path: String
        public var originalPath: String?
        public var kind: Kind
        public var id: String { path }
    }

    public enum Operation: String, Sendable {
        case merge, cherryPick, revert, rebase

        public var title: String {
            switch self {
            case .merge: "Merge"
            case .cherryPick: "Cherry-pick"
            case .revert: "Revert"
            case .rebase: "Rebase"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var branch: String?
        public var headSHA: String?
        public var upstream: String?
        public var ahead = 0
        public var behind = 0
        public var files: [FileStatus] = []
        public var inProgress: Operation?
        public var lastFetched: Date?

        public var conflicted: [FileStatus] { files.filter { $0.kind == .conflicted } }
    }

    public func status() -> Status? {
        guard let output = try? run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]).output else { return nil }
        var status = Self.parseStatus(output)
        // Not tracking anything yet, but origin has a branch of the same name: count against it.
        if status.upstream == nil, let branch = status.branch,
           let counts = try? run(["rev-list", "--left-right", "--count", "origin/\(branch)...HEAD"]).output {
            let parts = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            if parts.count == 2 {
                status.behind = parts[0]
                status.ahead = parts[1]
            }
        }
        if let directory = GitHead.gitDirectory(of: root) {
            let exists = { (name: String) in FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
            if exists("MERGE_HEAD") { status.inProgress = .merge }
            else if exists("CHERRY_PICK_HEAD") { status.inProgress = .cherryPick }
            else if exists("REVERT_HEAD") { status.inProgress = .revert }
            else if exists("rebase-merge") || exists("rebase-apply") { status.inProgress = .rebase }
            status.lastFetched = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("FETCH_HEAD").path))?[.modificationDate] as? Date
        }
        return status
    }

    /// `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        var records = output.components(separatedBy: "\0")[...]
        while let record = records.popFirst() {
            if record.hasPrefix("# branch.head ") {
                let name = String(record.dropFirst("# branch.head ".count))
                status.branch = name == "(detached)" ? nil : name
            } else if record.hasPrefix("# branch.oid ") {
                let sha = String(record.dropFirst("# branch.oid ".count))
                status.headSHA = sha == "(initial)" ? nil : sha
            } else if record.hasPrefix("# branch.upstream ") {
                status.upstream = String(record.dropFirst("# branch.upstream ".count))
            } else if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst("# branch.ab ".count).split(separator: " ")
                status.ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                status.behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") {
                let fields = record.split(separator: " ", maxSplits: record.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let xy = Array(fields[1])
                let path = String(fields[fields.count - 1])
                var original: String?
                if record.hasPrefix("2 ") { original = records.popFirst() }
                status.files.append(FileStatus(path: path, originalPath: original, kind: kind(x: xy[0], y: xy[1], renamed: original != nil)))
            } else if record.hasPrefix("u ") {
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = fields.last { status.files.append(FileStatus(path: String(path), kind: .conflicted)) }
            } else if record.hasPrefix("? ") {
                status.files.append(FileStatus(path: String(record.dropFirst(2)), kind: .untracked))
            }
        }
        status.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    private static func kind(x: Character, y: Character, renamed: Bool) -> FileStatus.Kind {
        if renamed { return .renamed }
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        return .modified
    }

    /// The working change of one file against HEAD (untracked files as all-new).
    public func diff(of file: FileStatus) -> String {
        switch file.kind {
        case .untracked:
            return (try? run(["diff", "--no-index", "--", "/dev/null", file.path], allowFailure: true).output) ?? ""
        case .conflicted:
            return (try? run(["diff", "--", file.path], allowFailure: true).output) ?? ""
        default:
            if (try? run(["rev-parse", "--verify", "HEAD"])) == nil {
                return (try? run(["diff", "--cached", "--", file.path]).output) ?? ""
            }
            return (try? run(["diff", "HEAD", "-M", "--", file.path]).output) ?? ""
        }
    }

    // MARK: Branches and stashes

    public struct Branch: Identifiable, Hashable, Sendable {
        public var name: String
        public var isRemote: Bool
        public var upstream: String?
        public var date: Date
        public var id: String { (isRemote ? "remote/" : "local/") + name }
    }

    public func branches() -> [Branch] {
        let format = "%(refname)%09%(upstream:short)%09%(committerdate:unix)"
        guard let output = try? run(["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"]).output else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { return nil }
            let ref = parts[0]
            let isRemote = ref.hasPrefix("refs/remotes/")
            let name = String(ref.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count))
            if isRemote, name.hasSuffix("/HEAD") { return nil }
            return Branch(name: name, isRemote: isRemote, upstream: parts[1].isEmpty ? nil : parts[1], date: Date(timeIntervalSince1970: TimeInterval(parts[2]) ?? 0))
        }
    }

    public struct Stash: Identifiable, Hashable, Sendable {
        public var ref: String
        public var message: String
        public var id: String { ref }
    }

    public func stashes() -> [Stash] {
        guard let output = try? run(["stash", "list", "--format=%gd%x09%s"]).output else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Stash(ref: parts[0], message: parts[1]) : nil
        }
    }

    // MARK: Writes

    /// A git (or gh) command that failed, with what it said.
    public struct Failure: LocalizedError, Equatable, Sendable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Commits exactly `paths` (staging new and deleted files first); other changes stay as they are.
    public func commit(paths: [String], summary: String, description: String) throws {
        guard !paths.isEmpty else { throw Failure(message: "Select at least one file to commit.") }
        try write(["add", "-A", "--"] + paths)
        let message = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? summary
            : summary + "\n\n" + description.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(["commit", "-m", message, "--"] + paths)
    }

    /// Conflicted files that still contain conflict markers.
    public func unresolved(_ files: [FileStatus]) -> [String] {
        files.filter { $0.kind == .conflicted }.map(\.path).filter { path in
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return false }
            return text.components(separatedBy: "\n").contains { $0.hasPrefix("<<<<<<< ") || $0 == "=======" || $0.hasPrefix(">>>>>>> ") }
        }
    }

    /// Finishes a merge, cherry-pick or revert once conflicts are resolved. Refuses while
    /// any conflicted file still has markers, so they are never committed by accident.
    public func continueOperation(_ operation: Operation) throws {
        let remaining = unresolved(status()?.files ?? [])
        guard remaining.isEmpty else {
            throw Failure(message: "Resolve the conflicts first: " + remaining.joined(separator: ", "))
        }
        try write(["add", "-A"])
        switch operation {
        case .merge: try write(["commit", "--no-edit"])
        case .cherryPick: try write(["cherry-pick", "--continue"])
        case .revert: try write(["revert", "--continue"])
        case .rebase: try write(["rebase", "--continue"])
        }
    }

    public func abort(_ operation: Operation) throws {
        switch operation {
        case .merge: try write(["merge", "--abort"])
        case .cherryPick: try write(["cherry-pick", "--abort"])
        case .revert: try write(["revert", "--abort"])
        case .rebase: try write(["rebase", "--abort"])
        }
    }

    /// Restores tracked files to HEAD. Untracked files are left to the caller (moved to the Trash).
    public func discard(_ files: [FileStatus]) throws {
        let tracked = files.filter { $0.kind != .untracked }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        guard !tracked.isEmpty else { return }
        try write(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + tracked)
    }

    public func ignore(_ path: String) throws {
        let file = root.appendingPathComponent(".gitignore")
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += path + "\n"
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw Failure(message: "Couldn't update .gitignore: \(error.localizedDescription)")
        }
    }

    public func fetch() throws {
        try write(["fetch", "--prune", "--all"])
    }

    /// Merges the upstream in (fast-forward when possible), as GitHub Desktop's Pull does.
    public func pull() throws {
        try write(["pull", "--no-rebase", "--no-edit"])
    }

    /// Pushes; a branch without an upstream is published to `origin` and tracks it.
    public func push(publishing branch: String? = nil) throws {
        if let branch {
            try write(["push", "--set-upstream", "origin", branch])
        } else {
            try write(["push"])
        }
    }

    /// Local branch, or a remote one checked out as a new tracking branch.
    public func checkout(_ branch: Branch) throws {
        if branch.isRemote {
            let local = branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
            if branches().contains(where: { !$0.isRemote && $0.name == local }) {
                try write(["switch", local])
            } else {
                try write(["switch", "-c", local, "--track", branch.name])
            }
        } else {
            try write(["switch", branch.name])
        }
    }

    /// `--no-track`: a branch started from `origin/staging` must not adopt it as upstream,
    /// or a plain push lands on staging. Publishing sets `origin/<name>` instead.
    public func createBranch(_ name: String, from start: String? = nil) throws {
        try write(["switch", "--no-track", "-c", name] + (start.map { [$0] } ?? []))
    }

    /// Refuses to delete a branch with unmerged commits.
    public func deleteBranch(_ name: String) throws {
        try write(["branch", "-d", name])
    }

    public func stash(message: String) throws {
        try write(["stash", "push", "--include-untracked", "-m", message])
    }

    public func popStash(_ stash: Stash) throws {
        try write(["stash", "pop", stash.ref])
    }

    public func dropStash(_ stash: Stash) throws {
        try write(["stash", "drop", stash.ref])
    }

    public func cherryPick(_ commit: GitLog.Commit) throws {
        try write(["cherry-pick"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.sha])
    }

    public func revert(_ commit: GitLog.Commit) throws {
        try write(["revert", "--no-edit"] + (commit.isMerge ? ["-m", "1"] : []) + [commit.sha])
    }

    public enum ResetMode: String, CaseIterable, Sendable {
        case soft, mixed, hard
    }

    public func reset(to sha: String, mode: ResetMode) throws {
        try write(["reset", "--\(mode.rawValue)", sha])
    }

    public func checkoutDetached(_ sha: String) throws {
        try write(["switch", "--detach", sha])
    }

    // MARK: Running

    struct Output {
        var status: Int32
        var output: String
    }

    private func write(_ arguments: [String]) throws {
        let result = try run(arguments, allowFailure: true)
        guard result.status == 0 else {
            throw Failure(message: Self.readable(result.output, command: arguments.first ?? "git"))
        }
    }

    /// Keeps git's own explanation, minus hint lines and blank noise.
    static func readable(_ output: String, command: String) -> String {
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("hint:") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = lines.suffix(6).joined(separator: "\n")
        return text.isEmpty ? "git \(command) failed." : text
    }

    @discardableResult
    func run(_ arguments: [String], allowFailure: Bool = false, environment extra: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = ExecutableLocator.find("git") ?? URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.quotepath=off", "-c", "color.ui=false"]
            + (try GitSafety.arguments(arguments, root: root, runsHooks: runsHooks))
        var environment = ExecutableLocator.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Reads (status every few seconds) mustn't take index.lock or rewrite .git/index.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment.merge(extra) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        guard allowFailure || output.status == 0 else { throw Failure(message: Self.readable(output.output, command: arguments.first ?? "git")) }
        return output
    }
}
