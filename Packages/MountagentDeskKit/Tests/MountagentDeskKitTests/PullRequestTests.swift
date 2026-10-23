import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct PullRequestTests {
    @Test func draftsTitleAndBody() {
        #expect(PullRequestDraft.title(session: "Wind limits for high trails", branch: "x") == "Wind limits for high trails")
        #expect(PullRequestDraft.title(session: "New session", branch: "mountagent/offline-maps-3f9a2c1d") == "Offline maps")
        let body = PullRequestDraft.body(summary: "Added wind limits.\n\nDetails follow.", commits: ["Add wind limits", "Test them"])
        #expect(body == "## Summary\n\nAdded wind limits.\n\n## Commits\n\n- Add wind limits\n- Test them")
        #expect(PullRequestDraft.body(summary: nil, commits: []) == "")
    }

    @Test func readsWhatGHPrints() {
        let created = "Creating pull request for feature into main in acme/trailhead\n\nhttps://github.com/acme/trailhead/pull/42\n"
        #expect(GitHubCLI.pullRequestURL(in: created)?.absoluteString == "https://github.com/acme/trailhead/pull/42")
        #expect(GitHubCLI.pullRequestURL(in: "a pull request already exists") == nil)
        let viewed = #"{"isDraft":false,"number":42,"state":"OPEN","url":"https://github.com/acme/trailhead/pull/42"}"#
        #expect(GitHubCLI.parsePullRequest(viewed)?.number == 42)
    }

    @Test func listsTheBranchsCommits() throws {
        let repo = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "switch", "-q", "-c", "feature")
        for name in ["one", "two"] {
            try name.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try git(repo, "add", name)
            try git(repo, "commit", "-q", "-m", "Add \(name)")
        }
        #expect(GitClient(root: repo).subjects(since: "main") == ["Add one", "Add two"])
    }

    private func makeRepository() throws -> URL {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("pr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try "x".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(repo, "add", "README")
        try git(repo, "commit", "-q", "-m", "First")
        return repo
    }

    private func git(_ repo: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "-c", "user.name=Alex Doe", "-c", "user.email=alex@example.com"] + arguments
        try process.run()
        process.waitUntilExit()
    }
}
