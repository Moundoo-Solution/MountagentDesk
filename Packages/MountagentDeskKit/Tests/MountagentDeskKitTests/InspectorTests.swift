import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct GitInspectorTests {
    private func shell(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        try process.run()
        process.waitUntilExit()
    }

    @Test func summarisesUncommittedChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskGit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try shell("""
        git init -q -b work && printf 'a\\nb\\nc\\n' > keep.py && printf 'x\\n' > gone.py && git add . && git commit -qm init && \
        printf 'a\\nB\\nc\\nd\\n' > keep.py && rm gone.py && printf '1\\n2\\n3\\n' > new.py && mkdir -p sub && printf 'z\\n' > sub/n.txt
        """, in: root)

        let inspector = GitInspector(root: root)
        let summary = try #require(inspector.summary())
        #expect(summary.branch == "work")
        let byPath = Dictionary(uniqueKeysWithValues: summary.changes.map { ($0.path, $0) })
        #expect(byPath["keep.py"]?.additions == 2)
        #expect(byPath["keep.py"]?.deletions == 1)
        #expect(byPath["gone.py"]?.status == .deleted)
        #expect(byPath["new.py"]?.status == .untracked)
        #expect(byPath["new.py"]?.additions == 3)
        #expect(byPath["sub/n.txt"]?.additions == 1)
        #expect(summary.additions == 6)
        #expect(summary.deletions == 2)

        let diff = inspector.diff(for: try #require(byPath["keep.py"]))
        #expect(diff.contains("-b"))
        #expect(diff.contains("+B"))
        #expect(inspector.diff(for: try #require(byPath["new.py"])).contains("+3"))
    }

    @Test func handlesNonRepositories() {
        #expect(GitInspector(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).summary() == nil)
    }

    @Test func readsRenamePaths() {
        #expect(GitInspector.renamedTarget("src/{old => new}/a.py") == "src/new/a.py")
        #expect(GitInspector.renamedTarget("a.py => b.py") == "b.py")
        #expect(GitInspector.renamedTarget("x.py") == "x.py")
    }
}

@Suite struct ForkTests {
    @Test func forksThroughAnItem() {
        var session = ChatSession(projectID: UUID(), title: "Fix", agent: .claude)
        session.models[.claude] = "opus"
        session.agentSessionIDs[.claude] = "abc"
        session.items = [ChatItem(kind: .user, text: "1"), ChatItem(kind: .assistant, agent: .claude, text: "2"), ChatItem(kind: .user, text: "3")]
        let fork = session.forked(through: session.items[1].id)
        #expect(fork.title == "Fork of Fix")
        #expect(fork.items.map(\.text) == ["1", "2"])
        #expect(fork.items[0].id != session.items[0].id)
        #expect(fork.agentSessionIDs.isEmpty)
        #expect(fork.models[.claude] == "opus")
        #expect(fork.unseenItems(for: .claude).count == 2, "the agent is handed the forked transcript")
    }
}

@Suite struct GitHeadTests {
    @Test func readsBranchesAndDetachedHeads() {
        #expect(GitHead.parse("ref: refs/heads/AB-005-U1-login-form\n") == "AB-005-U1-login-form")
        #expect(GitHead.parse("ref: refs/heads/feature/a/b") == "feature/a/b")
        #expect(GitHead.parse("4f1c9e2a7b3d5e6f7081928374655647382910ab\n") == "4f1c9e2a")
        #expect(GitHead.parse("") == nil)
    }

    @Test func followsGitFilesAndRealRepos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskHead-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", real.path, "init", "-q", "-b", "sub-tool"]
        try process.run()
        process.waitUntilExit()
        #expect(GitHead.branch(of: real) == "sub-tool")

        // A worktree-style checkout: `.git` is a file pointing at the git directory.
        let linked = root.appendingPathComponent("linked")
        let gitDir = root.appendingPathComponent("gitdirs/linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/session-2\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: ../gitdirs/linked\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(GitHead.branch(of: linked) == "session-2")

        #expect(GitHead.branch(of: root) == nil)
    }
}
