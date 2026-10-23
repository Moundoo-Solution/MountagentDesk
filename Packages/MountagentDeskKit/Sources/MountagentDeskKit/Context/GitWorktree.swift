import Foundation

/// A session's own working copy of a repository: a `git worktree` on a new branch, next to
/// the repository in `<name>.worktrees/`, so agents in several panes don't edit the same
/// files. Removing it keeps the branch, to merge or delete later.
public enum GitWorktree {
    public struct Created: Equatable, Sendable {
        public let path: URL
        public let branch: String
    }

    /// A branch `mountagent/<title words>-<short id>` from the repository's HEAD.
    public static func create(in repository: URL, title: String, id: UUID) throws -> Created {
        let short = String(id.uuidString.prefix(8)).lowercased()
        let slug = title.folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "[đĐ]", with: "d", options: .regularExpression)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let branch = "mountagent/" + (slug.isEmpty ? short : String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "-" + short)
        let folder = repository.deletingLastPathComponent()
            .appendingPathComponent(repository.lastPathComponent + ".worktrees", isDirectory: true)
            .appendingPathComponent(short, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GitClient(root: repository, runsHooks: false).run(["worktree", "add", "-q", "-b", branch, folder.path, "HEAD"])
        return Created(path: folder, branch: branch)
    }

    /// Removes the working copy (refused while it has uncommitted changes, unless `force`);
    /// the branch stays.
    public static func remove(_ path: URL, from repository: URL, force: Bool = false) throws {
        try GitClient(root: repository, runsHooks: false).run(["worktree", "remove"] + (force ? ["--force"] : []) + [path.path])
        let parent = path.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
