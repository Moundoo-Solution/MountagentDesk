import Foundation

/// The working tree as it was before an agent's turn, so the turn can be undone. A
/// checkpoint is a commit of every file (tracked and untracked, not ignored), built in a
/// temporary index and kept under `refs/mountagent/checkpoints/`: the files, the user's
/// index, HEAD and branches are left alone.
public enum GitCheckpoint {
    static let refPrefix = "refs/mountagent/checkpoints/"
    /// Plumbing commits need an author; these never land on a branch.
    static let identity = ["GIT_AUTHOR_NAME": "Mountagent Desk", "GIT_AUTHOR_EMAIL": "checkpoint@mountagent.invalid",
                           "GIT_COMMITTER_NAME": "Mountagent Desk", "GIT_COMMITTER_EMAIL": "checkpoint@mountagent.invalid"]

    public struct Change: Equatable, Sendable {
        /// `A`dded, `M`odified or `D`eleted since the checkpoint.
        public let status: Character
        public let path: String
    }

    /// Whether `root` is the top of a git work tree.
    public static func isRepository(_ root: URL) -> Bool {
        let output = try? GitClient(root: root, runsHooks: false).run(["rev-parse", "--show-toplevel"], allowFailure: true)
        guard let output, output.status == 0 else { return false }
        let top = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
    }

    /// Records the working tree under `name`; returns the checkpoint's commit.
    @discardableResult
    public static func create(in root: URL, name: String) throws -> String {
        let git = GitClient(root: root, runsHooks: false)
        let tree = try snapshotTree(git)
        let head = try? git.run(["rev-parse", "--verify", "-q", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = head.map { $0.isEmpty ? [] : ["-p", $0] } ?? []
        let commit = try git.run(["commit-tree", tree] + parent + ["-m", "Mountagent Desk checkpoint \(name)"], environment: identity)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["update-ref", refPrefix + name, commit])
        prune(git)
        return commit
    }

    /// How many checkpoints a repository keeps; older ones go (and git can drop their files).
    static let kept = 60

    private static func prune(_ git: GitClient) {
        guard let refs = try? git.run(["for-each-ref", "--sort=-committerdate", "--format=%(refname)", refPrefix]).output else { return }
        for ref in refs.split(separator: "\n").dropFirst(kept) {
            _ = try? git.run(["update-ref", "-d", String(ref)])
        }
    }

    /// What changed in the working tree since `checkpoint`.
    public static func changes(in root: URL, since checkpoint: String) throws -> [Change] {
        let git = GitClient(root: root, runsHooks: false)
        let now = try snapshotTree(git)
        let output = try git.run(["diff", "--name-status", "--no-renames", "-z", checkpoint, now]).output
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: fields.count - 1, by: 2).compactMap { index in
            fields[index].first.map { Change(status: $0, path: fields[index + 1]) }
        }
    }

    /// Puts the working tree back as it was at `checkpoint`: changed and deleted files
    /// come back, files added since go. The state just before is kept as `undoName` first,
    /// so the restore can be undone the same way. Commits made since stay; so does the index.
    @discardableResult
    public static func restore(in root: URL, to checkpoint: String, undoName: String) throws -> String {
        let git = GitClient(root: root, runsHooks: false)
        let undo = try create(in: root, name: undoName)
        let added = try changes(in: root, since: checkpoint).filter { $0.status == "A" }.map(\.path)
        try withTemporaryIndex(git) { environment in
            try git.run(["read-tree", checkpoint], environment: environment)
            try git.run(["checkout-index", "-a", "-f"], environment: environment)
        }
        let fileManager = FileManager.default
        let inside = root.resolvingSymlinksInPath().path + "/"
        for path in added {
            let file = root.appendingPathComponent(path)
            // Through a folder the turn turned into a link, the path could lead elsewhere.
            guard file.deletingLastPathComponent().resolvingSymlinksInPath().path.appending("/").hasPrefix(inside) else { continue }
            try? fileManager.removeItem(at: file)
            // Folders the turn created and that are empty now go too.
            var folder = file.deletingLastPathComponent()
            while folder.path.count > root.path.count,
                  (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fileManager.removeItem(at: folder)
                folder = folder.deletingLastPathComponent()
            }
        }
        return undo
    }

    /// The working tree as a tree object, staged in a copy of the real index (so only
    /// changed files are hashed again).
    private static func snapshotTree(_ git: GitClient) throws -> String {
        try withTemporaryIndex(git, seeded: true) { environment in
            try git.run(["add", "-A"], environment: environment)
            return try git.run(["write-tree"], environment: environment).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func withTemporaryIndex<Value>(_ git: GitClient, seeded: Bool = false, _ body: ([String: String]) throws -> Value) throws -> Value {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("mountagent-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        if seeded {
            let real = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "index"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: real), to: index)
        }
        return try body(["GIT_INDEX_FILE": index.path])
    }
}
