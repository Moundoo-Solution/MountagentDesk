import Foundation

/// Rewriting history: squashing a run of commits, undoing that, and force-pushing the
/// result. Before rewriting, the branch's tip is saved under `refs/mountagent/backup/<branch>`
/// so Undo can put everything back.
extension GitClient {
    /// Branches where commits already on origin are never rewritten: the whole team builds on them.
    public static let protectedBranches: Set<String> = ["main", "master", "staging", "production"]

    public struct SquashPlan: Equatable, Sendable {
        public var branch: String
        /// The selection, oldest first.
        public var commits: [GitLog.Commit]
        /// Some of them are already on a remote: squashing needs a force push.
        public var isPushed: Bool
        /// The proposed message: the oldest subject, then the others as a list.
        public var message: String
    }

    /// Checks that `selection` can be squashed on the current branch and describes how.
    /// Throws a `Failure` saying why not otherwise.
    public func planSquash(_ selection: [GitLog.Commit]) throws -> SquashPlan {
        guard selection.count >= 2 else { throw Failure(message: "Pick at least two commits to squash.") }
        guard let status = status() else { throw Failure(message: "Couldn't read the repository.") }
        guard let branch = status.branch else { throw Failure(message: "Check out a branch first; HEAD is detached.") }
        guard status.inProgress == nil else { throw Failure(message: "Finish or abort the \(status.inProgress!.title.lowercased()) first.") }
        guard !status.files.contains(where: { $0.kind != .untracked }) else {
            throw Failure(message: "Commit or stash your changes first; squashing rewrites the working tree.")
        }
        guard !selection.contains(where: \.isMerge) else { throw Failure(message: "Merge commits can't be squashed.") }

        // The branch's own line of commits, newest first.
        let line = try run(["rev-list", "--first-parent", "HEAD"]).output.split(separator: "\n").map(String.init)
        let positions = selection.compactMap { commit in line.firstIndex(of: commit.sha) }
        guard positions.count == selection.count else {
            throw Failure(message: "Only commits on \(branch) can be squashed. Switch to the branch that has them.")
        }
        let sorted = positions.sorted()
        guard sorted.last! - sorted.first! == sorted.count - 1 else {
            throw Failure(message: "The commits must be next to each other in the history.")
        }
        // Rebasing replays everything after them, which would flatten merges.
        let newerMerges = try run(["rev-list", "--merges", "--first-parent", "-n", "1", "\(line[sorted.first!])..HEAD"]).output
        guard newerMerges.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "There is a merge commit after these, so they can't be squashed without rewriting it.")
        }

        let oldestFirst = sorted.reversed().map { index in selection.first { $0.sha == line[index] }! }
        let newest = oldestFirst.last!
        let remotes = try run(["branch", "-r", "--contains", newest.sha], allowFailure: true).output
        let isPushed = !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isPushed, Self.protectedBranches.contains(branch) {
            throw Failure(message: "These commits are already on origin/\(branch). Rewriting \(branch) would break everyone's copy, so Mountagent Desk won't squash them.")
        }
        return SquashPlan(branch: branch, commits: oldestFirst, isPushed: isPushed, message: Self.squashMessage(oldestFirst))
    }

    static func squashMessage(_ commits: [GitLog.Commit]) -> String {
        guard let first = commits.first else { return "" }
        let rest = commits.dropFirst().map { "- \($0.subject)" }
        return ([first.subject, ""] + rest).joined(separator: "\n")
    }

    /// Squashes the plan's commits into one with `message`, keeping the oldest one's author
    /// and replaying anything newer on top. The previous tip is saved for `undoSquash`.
    public func squash(_ plan: SquashPlan, message: String) throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw Failure(message: "The commit message can't be empty.") }
        guard let oldest = plan.commits.first, let newest = plan.commits.last else { return }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskSquash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let messageFile = work.appendingPathComponent("message.txt")
        try message.write(to: messageFile, atomically: true, encoding: .utf8)

        let head = try run(["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let isRoot = oldest.parents.isEmpty
        let range = isRoot ? "HEAD" : "\(oldest.sha)^..HEAD"
        let replay = try run(["rev-list", "--reverse", "--first-parent", range]).output.split(separator: "\n").map(String.init)
        let selected = Set(plan.commits.map(\.sha))

        // The whole todo is written up front; git only has to copy it into place.
        var todo: [String] = []
        for sha in replay {
            if sha == oldest.sha {
                todo.append("pick \(sha)")
            } else if selected.contains(sha) {
                todo.append("fixup \(sha)")
            } else {
                todo.append("pick \(sha)")
            }
            if sha == newest.sha {
                todo.append("exec git commit --amend --allow-empty --no-verify -F \(Shell.quote(messageFile.path))")
            }
        }
        let todoFile = work.appendingPathComponent("todo.txt")
        try (todo.joined(separator: "\n") + "\n").write(to: todoFile, atomically: true, encoding: .utf8)

        try run(["update-ref", Self.backupRef(plan.branch), head])
        let result = try run(["rebase", "-i", "--no-autosquash"] + (isRoot ? ["--root"] : ["\(oldest.sha)^"]),
                             allowFailure: true,
                             environment: ["GIT_SEQUENCE_EDITOR": "cp \(Shell.quote(todoFile.path))"])
        if result.status != 0 {
            _ = try? run(["rebase", "--abort"], allowFailure: true)
            throw Failure(message: "Squash failed and nothing was changed:\n" + Self.readable(result.output, command: "rebase"))
        }
    }

    /// The tip saved before the last squash on `branch`, if there is one to go back to.
    public func squashBackup(for branch: String) -> String? {
        let output = try? run(["rev-parse", "--verify", "--quiet", Self.backupRef(branch)], allowFailure: true)
        guard let output, output.status == 0 else { return nil }
        let sha = output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Puts `branch` back where it was before the last squash.
    public func undoSquash(on branch: String) throws {
        guard let backup = squashBackup(for: branch) else { throw Failure(message: "There is no squash to undo on \(branch).") }
        guard status()?.branch == branch else { throw Failure(message: "Switch to \(branch) to undo its squash.") }
        guard status()?.files.contains(where: { $0.kind != .untracked }) == false else {
            throw Failure(message: "Commit or stash your changes first.")
        }
        try run(["reset", "--hard", backup])
        try run(["update-ref", "-d", Self.backupRef(branch)])
    }

    /// Forgets the backup, e.g. once the squash has been pushed.
    public func dropSquashBackup(for branch: String) {
        _ = try? run(["update-ref", "-d", Self.backupRef(branch)], allowFailure: true)
    }

    /// Replaces the branch on origin with this one, but only if origin still has what was
    /// last fetched; someone else's new commits make it fail instead of vanishing.
    public func forcePush() throws {
        guard let branch = status()?.branch else { throw Failure(message: "Check out a branch first.") }
        if Self.protectedBranches.contains(branch) {
            throw Failure(message: "Mountagent Desk doesn't force-push \(branch).")
        }
        let result = try run(["push", "--force-with-lease", "origin", "HEAD:\(branch)"], allowFailure: true)
        guard result.status == 0 else { throw Failure(message: Self.readable(result.output, command: "push")) }
        dropSquashBackup(for: branch)
    }

    static func backupRef(_ branch: String) -> String {
        "refs/mountagent/backup/\(branch)"
    }
}
