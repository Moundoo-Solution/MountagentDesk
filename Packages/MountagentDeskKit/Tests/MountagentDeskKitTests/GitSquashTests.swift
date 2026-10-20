import Foundation
import Testing
@testable import MountagentDeskKit

@Suite(.serialized) struct GitSquashTests {
    private func sh(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "GIT_AUTHOR_NAME": "Ann", "GIT_AUTHOR_EMAIL": "ann@x.com",
                               "GIT_COMMITTER_NAME": "Ann", "GIT_COMMITTER_EMAIL": "ann@x.com"]
        try process.run()
        process.waitUntilExit()
    }

    /// A clone of a bare remote on branch `feature`: A pushed, then B, C, D local only.
    private func setUp(branch: String = "feature") throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskSquash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try sh("""
        git init -q --bare -b \(branch) remote.git
        git clone -q remote.git work 2>/dev/null
        cd work && git config user.name Ann && git config user.email ann@x.com
        echo a > a.txt && git add . && git commit -qm A && git push -q origin \(branch) 2>/dev/null
        echo b > b.txt && git add . && git commit -qm B
        echo c > c.txt && git add . && git commit -qm C
        echo d > d.txt && git add . && git commit -qm D
        """, in: base)
        return base.appendingPathComponent("work")
    }

    private func history(_ root: URL) -> [GitLog.Commit] {
        GitLog.commits(in: root, branch: "HEAD", limit: 50)
    }

    @Test func squashesCommitsInTheMiddleAndUndoes() throws {
        let root = try setUp()
        let client = GitClient(root: root)
        let before = history(root)
        #expect(before.map(\.subject) == ["D", "C", "B", "A"])

        let plan = try client.planSquash([before[1], before[2]])
        #expect(plan.commits.map(\.subject) == ["B", "C"], "oldest first")
        #expect(!plan.isPushed)
        #expect(plan.message == "B\n\n- C")

        try client.squash(plan, message: "B and C together")
        let after = history(root)
        #expect(after.map(\.subject) == ["D", "B and C together", "A"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.txt").path))
        #expect(client.squashBackup(for: "feature") == before[0].sha)

        try client.undoSquash(on: "feature")
        #expect(history(root).map(\.sha) == before.map(\.sha))
        #expect(client.squashBackup(for: "feature") == nil)
    }

    @Test func squashesTheNewestAndTheFirstCommits() throws {
        let root = try setUp()
        let client = GitClient(root: root)
        var commits = history(root)
        try client.squash(try client.planSquash([commits[0], commits[1]]), message: "C+D")
        #expect(history(root).map(\.subject) == ["C+D", "B", "A"])

        commits = history(root)
        try client.squash(try client.planSquash([commits[1], commits[2]]), message: "Start")
        #expect(history(root).map(\.subject) == ["C+D", "Start"], "the root commit can be squashed too")
    }

    @Test func refusesWhatItCannotSquashSafely() throws {
        let root = try setUp()
        let client = GitClient(root: root)
        let commits = history(root)
        #expect(throws: GitClient.Failure.self) { try client.planSquash([commits[0], commits[2]]) }   // D and B: not adjacent
        #expect(throws: GitClient.Failure.self) { try client.planSquash([commits[0]]) }

        try sh("echo changed > a.txt", in: root)
        #expect(throws: GitClient.Failure.self) { try client.planSquash([commits[0], commits[1]]) }
        try sh("git checkout -q -- a.txt", in: root)

        // Pushed commits on a team branch stay as they are.
        let team = try setUp(branch: "staging")
        let teamClient = GitClient(root: team)
        try sh("git push -q origin staging 2>/dev/null", in: team)
        let pushed = history(team)
        #expect(throws: GitClient.Failure.self) { try teamClient.planSquash([pushed[0], pushed[1]]) }
        #expect(throws: GitClient.Failure.self) { try teamClient.forcePush() }
    }

    @Test func forcePushesARewrittenFeatureBranch() throws {
        let root = try setUp()
        let client = GitClient(root: root)
        try sh("git push -q -u origin feature 2>/dev/null", in: root)
        let commits = history(root)
        let plan = try client.planSquash([commits[0], commits[1]])
        #expect(plan.isPushed)
        try client.squash(plan, message: "C+D")
        #expect(client.status()?.ahead == 1)
        #expect(client.status()?.behind == 2)

        try client.forcePush()
        try client.fetch()
        #expect(client.status()?.ahead == 0)
        #expect(client.status()?.behind == 0)
        #expect(client.squashBackup(for: "feature") == nil)
    }
}
