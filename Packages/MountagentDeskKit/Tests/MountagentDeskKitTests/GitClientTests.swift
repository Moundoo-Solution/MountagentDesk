import Foundation
import Testing
@testable import MountagentDeskKit

@Suite(.serialized) struct GitClientTests {
    private func sh(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        try process.run()
        process.waitUntilExit()
    }

    /// A clone of a bare remote, with one commit on main already pushed.
    private func setUp() throws -> (base: URL, clone: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskClient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try sh("""
        git init -q --bare -b main remote.git
        git clone -q remote.git work 2>/dev/null
        cd work && git config user.name t && git config user.email t@t
        printf 'a\\nb\\n' > app.py && git add . && git commit -qm init && git push -q origin main 2>/dev/null
        """, in: base)
        return (base, base.appendingPathComponent("work"))
    }

    @Test func commitsOnlyTheSelectedFiles() throws {
        let (_, work) = try setUp()
        try sh("printf 'a\\nB\\n' > app.py && printf 'x\\n' > new.py && printf 'y\\n' > other.py", in: work)
        let client = GitClient(root: work)
        let status = try #require(client.status())
        #expect(status.branch == "main")
        #expect(Set(status.files.map(\.path)) == ["app.py", "new.py", "other.py"])
        #expect(status.files.first { $0.path == "new.py" }?.kind == .untracked)

        try client.commit(paths: ["app.py", "new.py"], summary: "Change app", description: "Body line")
        let after = try #require(client.status())
        #expect(after.files.map(\.path) == ["other.py"])
        #expect(after.ahead == 1)
        let last = GitLog.commits(in: work, branch: "HEAD", limit: 1).first
        #expect(last?.subject == "Change app")
        #expect(GitLog.detail(of: try #require(last), in: work).message == "Change app\n\nBody line")
    }

    @Test func pushesPullsAndPublishes() throws {
        let (base, work) = try setUp()
        let client = GitClient(root: work)

        // Another clone pushes; fetch shows we are behind, pull brings it in.
        try sh("git clone -q remote.git other 2>/dev/null && cd other && git config user.name o && git config user.email o@o && printf 'c\\n' > c.py && git add . && git commit -qm theirs && git push -q 2>/dev/null", in: base)
        try client.fetch()
        #expect(client.status()?.behind == 1)
        #expect(client.status()?.lastFetched != nil)
        try client.pull()
        #expect(client.status()?.behind == 0)
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("c.py").path))

        // A new branch has no upstream until it is published.
        try client.createBranch("feature")
        try sh("printf 'f\\n' > f.py", in: work)
        try client.commit(paths: ["f.py"], summary: "Feature", description: "")
        #expect(client.status()?.upstream == nil)
        #expect(client.status()?.ahead == 0, "nothing on origin to compare with yet")
        try client.push(publishing: "feature")
        #expect(client.status()?.upstream == "origin/feature")
        #expect(client.branches().contains { $0.isRemote && $0.name == "origin/feature" })
    }

    @Test func branchesFromARemoteWithoutTrackingIt() throws {
        let (_, work) = try setUp()
        let client = GitClient(root: work)
        try client.createBranch("hotfix", from: "origin/main")
        let status = try #require(client.status())
        #expect(status.branch == "hotfix")
        #expect(status.upstream == nil, "pushing must not land on main")
        try client.push(publishing: "hotfix")
        #expect(client.status()?.upstream == "origin/hotfix")
    }

    @Test func cherryPicksRevertsAndRecoversFromConflicts() throws {
        let (_, work) = try setUp()
        let client = GitClient(root: work)
        try client.createBranch("fix")
        try sh("printf 'a\\nFIX\\n' > app.py && git commit -qam fix", in: work)
        let fix = try #require(GitLog.commits(in: work, branch: "fix", limit: 1).first)

        try client.checkout(GitClient.Branch(name: "main", isRemote: false, date: .now))
        try client.cherryPick(fix)
        #expect(try String(contentsOf: work.appendingPathComponent("app.py"), encoding: .utf8) == "a\nFIX\n")

        let picked = try #require(GitLog.commits(in: work, branch: "HEAD", limit: 1).first)
        try client.revert(picked)
        #expect(try String(contentsOf: work.appendingPathComponent("app.py"), encoding: .utf8) == "a\nb\n")

        // Conflict: main changes the same line, then the fix is picked again.
        try sh("printf 'a\\nMAIN\\n' > app.py && git commit -qam main", in: work)
        #expect(throws: GitClient.Failure.self) { try client.cherryPick(fix) }
        let status = try #require(client.status())
        #expect(status.inProgress == .cherryPick)
        #expect(status.conflicted.map(\.path) == ["app.py"])
        #expect(throws: GitClient.Failure.self) { try client.continueOperation(.cherryPick) }
        #expect(client.unresolved(status.files) == ["app.py"])
        try client.abort(.cherryPick)
        #expect(client.status()?.inProgress == nil)
        #expect(client.status()?.files.isEmpty == true)
    }

    @Test func stashesDiscardsResetsAndManagesBranches() throws {
        let (_, work) = try setUp()
        let client = GitClient(root: work)

        try sh("printf 'z\\n' >> app.py && printf 'u\\n' > untracked.py", in: work)
        try client.stash(message: "Mountagent Desk: main")
        #expect(client.status()?.files.isEmpty == true)
        let stash = try #require(client.stashes().first)
        #expect(stash.message.contains("Mountagent Desk: main"))
        try client.popStash(stash)
        #expect(client.status()?.files.count == 2)

        let modified = try #require(client.status()?.files.first { $0.path == "app.py" })
        #expect(client.diff(of: modified).contains("+z"))
        try client.discard([modified])
        #expect(client.status()?.files.map(\.path) == ["untracked.py"])

        try client.ignore("untracked.py")
        #expect(client.status()?.files.map(\.path) == [".gitignore"])

        try client.createBranch("temp")
        try client.checkout(GitClient.Branch(name: "main", isRemote: false, date: .now))
        try client.deleteBranch("temp")
        #expect(!client.branches().contains { $0.name == "temp" })

        try sh("git add .gitignore && git commit -qm ignore", in: work)
        let initial = try #require(GitLog.commits(in: work, branch: "HEAD", limit: 2).last)
        try client.reset(to: initial.sha, mode: .mixed)
        #expect(client.status()?.files.map(\.path) == [".gitignore"])
        #expect(GitClient.readable("hint: x\nerror: nope\n", command: "push") == "error: nope")
    }

    @Test func parsesPorcelainStatus() {
        let output = [
            "# branch.oid abc", "# branch.head AB-005", "# branch.upstream origin/AB-005", "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 h1 h2 src/a b.py",
            "2 R. N... 100644 100644 100644 h1 h2 R100 new.py", "old.py",
            "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.py",
            "? notes.md", "",
        ].joined(separator: "\0")
        let status = GitClient.parseStatus(output)
        #expect(status.branch == "AB-005")
        #expect(status.ahead == 2 && status.behind == 3)
        #expect(status.files.map(\.path) == ["conflict.py", "new.py", "notes.md", "src/a b.py"])
        #expect(status.files.first { $0.path == "new.py" }?.originalPath == "old.py")
        #expect(status.files.first { $0.path == "new.py" }?.kind == .renamed)
        #expect(status.files.first { $0.path == "conflict.py" }?.kind == .conflicted)
    }
}
