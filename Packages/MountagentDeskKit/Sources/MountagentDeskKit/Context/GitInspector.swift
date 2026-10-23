import Foundation

/// Working-tree state of a project folder (changes, diffs, the file tree), read with the
/// `git` CLI; also the plain `git` runner other git helpers use.
public struct GitInspector: Sendable {
    public struct FileChange: Identifiable, Hashable, Sendable {
        public enum Status: String, Sendable {
            case modified, added, deleted, renamed, untracked
        }

        public var path: String
        public var additions: Int
        public var deletions: Int
        public var status: Status
        public var isBinary: Bool
        public var id: String { path }
    }

    public struct Summary: Hashable, Sendable {
        public var branch: String?
        public var changes: [FileChange]
        public var additions: Int { changes.reduce(0) { $0 + $1.additions } }
        public var deletions: Int { changes.reduce(0) { $0 + $1.deletions } }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var isRepository: Bool {
        (try? git(["rev-parse", "--is-inside-work-tree"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Uncommitted changes against HEAD, untracked files included (counted as all-new lines).
    public func summary() -> Summary? {
        guard isRepository else { return nil }
        var changes: [String: FileChange] = [:]

        let hasHead = (try? git(["rev-parse", "--verify", "HEAD"])) != nil
        let numstat = (try? git(hasHead ? ["diff", "HEAD", "--numstat", "-M"] : ["diff", "--cached", "--numstat"])) ?? ""
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-"
            let path = Self.renamedTarget(parts[2])
            changes[path] = FileChange(
                path: path,
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0,
                status: parts[2].contains("=>") ? .renamed : .modified,
                isBinary: binary
            )
        }

        let status = (try? git(["status", "--porcelain=v1", "--untracked-files=all"])) ?? ""
        for line in status.split(separator: "\n") where line.count > 3 {
            let code = line.prefix(2)
            let path = Self.renamedTarget(String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            switch code {
            case "??":
                let lines = Self.lineCount(root.appendingPathComponent(path))
                changes[path] = FileChange(path: path, additions: lines ?? 0, deletions: 0, status: .untracked, isBinary: lines == nil)
            case _ where code.contains("D"):
                changes[path]?.status = .deleted
            case _ where code.contains("A"):
                changes[path]?.status = .added
            default:
                break
            }
        }

        return Summary(branch: GitHead.branch(of: root), changes: changes.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    /// Unified diff of one file against HEAD; untracked files show as entirely added.
    public func diff(for change: FileChange) -> String {
        if change.status == .untracked {
            return (try? git(["diff", "--no-index", "--", "/dev/null", change.path], allowFailure: true)) ?? ""
        }
        return (try? git(["diff", "HEAD", "-M", "--", change.path])) ?? ""
    }

    // MARK: Helpers

    /// `old => new` and `dir/{old => new}/file` forms from git, reduced to the new path.
    static func renamedTarget(_ path: String) -> String {
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"), open < close {
            let inner = path[path.index(after: open)..<close]
            let target = inner.components(separatedBy: " => ").last ?? String(inner)
            return (String(path[..<open]) + target + String(path[path.index(after: close)...])).replacingOccurrences(of: "//", with: "/")
        }
        if path.contains(" -> ") { return path.components(separatedBy: " -> ").last ?? path }
        return path.components(separatedBy: " => ").last ?? path
    }

    static func lineCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 20_000_000 else { return nil }
        if data.prefix(8000).contains(0) { return nil }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return newlines + (data.last == 0x0A || data.isEmpty ? 0 : 1)
    }

    @discardableResult
    func git(_ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = ExecutableLocator.find("git") ?? URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "core.quotepath=off"] + (try GitSafety.arguments(arguments, root: root, runsHooks: true))
        var environment = ExecutableLocator.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read stderr alongside, so a chatty command can't fill its pipe and stall.
        let errorText = OutputBuffer()
        let stderrDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorText.append(errors.fileHandleForReading.readDataToEndOfFile())
            stderrDone.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stderrDone.wait()
        guard allowFailure || process.terminationStatus == 0 else {
            throw GitClient.Failure(message: GitClient.readable(errorText.text, command: arguments.first ?? "git"))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Lists a folder for the Files panel, hiding build output and VCS internals.
public enum FileTree {
    public struct Node: Identifiable, Hashable, Sendable {
        public var url: URL
        public var isDirectory: Bool
        public var id: String { url.path }

        public init(url: URL, isDirectory: Bool) {
            self.url = url
            self.isDirectory = isDirectory
        }
        public var name: String { url.lastPathComponent }
    }

    public static let hidden: Set<String> = [".git", ".DS_Store", "node_modules", "__pycache__", ".build", ".swiftpm", "DerivedData", ".venv", "venv", ".idea", ".pytest_cache", ".mypy_cache"]

    /// Folders first, then files, each in Finder order.
    public static func children(of url: URL) -> [Node] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return entries
            .filter { !hidden.contains($0.lastPathComponent) }
            .map { Node(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// The start of a text file for preview; `nil` for binaries.
    public static func preview(_ url: URL, limit: Int = 200_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        if data.prefix(8000).contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The checked-out branch, read straight from `HEAD` (no `git` process), so it can be
/// re-read whenever the repository changes.
public enum GitHead {
    /// The repository's git directory: `.git`, or where a `.git` file points (worktrees,
    /// submodules).
    public static func gitDirectory(of root: URL) -> URL? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
    }

    /// Branch name, or the short commit when HEAD is detached.
    public static func branch(of root: URL) -> String? {
        guard let directory = gitDirectory(of: root),
              let head = try? String(contentsOf: directory.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        return parse(head)
    }

    static func parse(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst("ref: ".count)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
        }
        return line.count >= 7 ? GitLog.short(line) : nil
    }
}
