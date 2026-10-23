import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct GitCheckpointTests {
    private func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = GitClient(root: root)
        try git.run(["init", "-q"])
        try "keep\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "ignored.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", "first"], environment: GitCheckpoint.identity)
        return root
    }

    @Test func undoesATurnAndTheUndo() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        // Uncommitted work from before the turn is part of the checkpoint.
        try "draft\n".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        #expect(GitCheckpoint.isRepository(root))
        let before = try GitCheckpoint.create(in: root, name: "s/1")
        let status = try GitClient(root: root).run(["status", "--porcelain"]).output
        #expect(status.contains("?? draft.txt"), "the index and files are untouched")

        // The turn: edits, deletes, adds a file in a new folder, writes an ignored file.
        try "changed\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("draft.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("new/deep"), withIntermediateDirectories: true)
        try "x\n".write(to: root.appendingPathComponent("new/deep/b.txt"), atomically: true, encoding: .utf8)
        try "log\n".write(to: root.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)

        let changes = try GitCheckpoint.changes(in: root, since: before)
        #expect(Set(changes.map { "\($0.status) \($0.path)" }) == ["M a.txt", "D draft.txt", "A new/deep/b.txt"])

        let undo = try GitCheckpoint.restore(in: root, to: before, undoName: "s/1-undo")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "keep\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("draft.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("ignored.log").path), "ignored files are left alone")
        #expect(try GitCheckpoint.changes(in: root, since: before).isEmpty)

        // And back again.
        try GitCheckpoint.restore(in: root, to: undo, undoName: "s/1-redo")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("new/deep/b.txt").path))
        let refs = try GitClient(root: root).run(["for-each-ref", "--format=%(refname)", "refs/mountagent/"]).output
        #expect(refs.contains("refs/mountagent/checkpoints/s/1\n") && refs.contains("s/1-undo") && refs.contains("s/1-redo"))
    }

    @Test func worksBeforeTheFirstCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try GitClient(root: root).run(["init", "-q"])
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let before = try GitCheckpoint.create(in: root, name: "x")
        try "b\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitCheckpoint.restore(in: root, to: before, undoName: "x-undo")
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
    }
}

@Suite struct GitWorktreeTests {
    @Test func createsAndRemovesASessionsWorktree() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("addons")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let git = GitClient(root: repo)
        try git.run(["init", "-q"])
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", "first"], environment: GitCheckpoint.identity)

        let id = UUID()
        let created = try GitWorktree.create(in: repo, title: "Sửa báo giá: total!", id: id)
        #expect(created.branch == "mountagent/sua-bao-gia-total-" + id.uuidString.prefix(8).lowercased())
        #expect(created.path.deletingLastPathComponent().lastPathComponent == "addons.worktrees")
        #expect(try String(contentsOf: created.path.appendingPathComponent("a.txt"), encoding: .utf8) == "a\n")
        #expect(GitCheckpoint.isRepository(created.path))

        try "dirty\n".write(to: created.path.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try GitWorktree.remove(created.path, from: repo) }
        try GitWorktree.remove(created.path, from: repo, force: true)

        // Named branches: a new one from HEAD, then an existing one checked out.
        let fresh = try GitWorktree.create(in: repo, branch: "feature/quotes", id: UUID())
        #expect(fresh.branch == "feature/quotes")
        try GitWorktree.remove(fresh.path, from: repo)
        let again = try GitWorktree.create(in: repo, branch: "feature/quotes", id: UUID())
        #expect(try git.run(["-C", again.path.path, "branch", "--show-current"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "feature/quotes")
        try GitWorktree.remove(again.path, from: repo)
        #expect(throws: (any Error).self) { try GitWorktree.create(in: repo, branch: "bad..name", id: UUID()) }
        #expect(GitWorktree.branches(in: repo).contains("feature/quotes"))
        #expect(!FileManager.default.fileExists(atPath: created.path.path))
        #expect(!FileManager.default.fileExists(atPath: created.path.deletingLastPathComponent().path))
        #expect(try git.run(["branch", "--list", created.branch]).output.contains(created.branch))
    }
}

@Suite struct GitSafetyTests {
    @Test func plantedProgramsDontRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)")
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("safety-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marks, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: marks)
        }
        let git = GitClient(root: root)
        try git.run(["init", "-q"])
        try "a\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git.run(["add", "-A"])
        try git.run(["commit", "-q", "-m", "first"], environment: GitCheckpoint.identity)
        // What an agent could plant: each program leaves a mark if it runs.
        func mark(_ name: String) -> String { "touch '\(marks.path)/\(name)'; cat" }
        try git.run(["config", "filter.p.clean", mark("clean")])
        try git.run(["config", "filter.p.smudge", mark("smudge")])
        try git.run(["config", "diff.p.textconv", mark("textconv")])
        try git.run(["config", "core.fsmonitor", "touch '\(marks.path)/fsmonitor'; true #"])
        let hooks = root.appendingPathComponent(".git/hooks/post-checkout")
        try "#!/bin/sh\ntouch '\(marks.path)/hook'\n".write(to: hooks, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.path)
        try "*.txt filter=p diff=p\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "b\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // The app's own git work: status, diff, a checkpoint and its restore, a worktree.
        _ = try git.status()
        _ = try GitInspector(root: root).git(["diff", "HEAD"])
        let before = try GitCheckpoint.create(in: root, name: "t")
        try "c\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitCheckpoint.restore(in: root, to: before, undoName: "t-undo")
        let worktree = try GitWorktree.create(in: root, title: "t", id: UUID())
        try GitWorktree.remove(worktree.path, from: root, force: true)

        #expect(try FileManager.default.contentsOfDirectory(atPath: marks.path).isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "b\n")
    }

    @Test func refusesRepositoriesWithAProcessFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitClient(root: root)
        try git.run(["init", "-q"])
        try git.run(["config", "filter.q.process", "touch /tmp/never"])
        #expect(throws: GitSafety.Refusal.self) { try git.run(["status"]) }
        #expect(git.status() == nil)
    }

    @Test func trustsTheUsersOwnFiltersAndLFS() {
        let drivers = GitSafety.parse("""
        global\tfilter.lfs.process git-lfs filter-process
        local\tfilter.lfs.clean git-lfs clean -- %f
        local\tfilter.lfs.required true
        local\tfilter.evil.clean sh x
        worktree\tfilter.a.b.process run
        """)
        #expect(drivers == [GitSafety.Driver(name: "evil"), GitSafety.Driver(name: "a.b", hasProcess: true)])
    }
}
