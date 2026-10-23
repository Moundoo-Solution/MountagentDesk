import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct GitLogTests {
    private func sh(_ command: String, in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": NSHomeDirectory(),
                               "GIT_AUTHOR_NAME": "Ann Lee", "GIT_AUTHOR_EMAIL": "m@x.com",
                               "GIT_COMMITTER_NAME": "Ann Lee", "GIT_COMMITTER_EMAIL": "m@x.com"]
        try process.run()
        process.waitUntilExit()
    }

    /// main: A ─ B ─ M (merge of feature);  feature: A ─ C
    private func mergedRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskLog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sh("""
        git init -q -b main
        c() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git commit -q --allow-empty -m "$2"; }
        c "2026-10-01T10:00:00" "A: start"
        git checkout -q -b feature
        c "2026-10-03T10:00:00" "C: feature work (task 9715)"
        git checkout -q main
        c "2026-10-02T10:00:00" "B: main work"
        GIT_AUTHOR_DATE="2026-10-04T10:00:00" GIT_COMMITTER_DATE="2026-10-04T10:00:00" git merge -q --no-ff feature -m "M: merge feature"
        git tag v1
        """, in: root)
        return root
    }

    @Test func readsCommitsWithRefs() throws {
        let commits = GitLog.commits(in: try mergedRepo(), branch: "main")
        #expect(commits.map { String($0.subject.prefix(1)) } == ["M", "C", "B", "A"])
        let merge = try #require(commits.first)
        #expect(merge.isMerge)
        #expect(merge.author == "Ann Lee")
        #expect(merge.refs == ["main", "v1"])
        #expect(commits[1].refs == ["feature"])
        #expect(Calendar.current.component(.day, from: commits[3].date) == 1)
    }

    @Test func parsesDecorations() {
        let refs = GitLog.parseRefs("HEAD -> AB-005-U1-login-form, origin/staging, staging, tag: v1.0, origin/HEAD, feature/x")
        #expect(refs == ["AB-005-U1-login-form", "origin/staging", "staging", "v1.0", "feature/x"])
    }

    @Test func detailsCommitsAndBranchScope() throws {
        let root = try mergedRepo()
        let feature = GitLog.commits(in: root, branch: "feature")
        #expect(feature.map { String($0.subject.prefix(1)) } == ["C", "A"])
        let detail = GitLog.detail(of: feature[0], in: root)
        #expect(detail.message == "C: feature work (task 9715)")
        #expect(detail.files.isEmpty)
    }

    @Test func readsReferencesFromSubjects() {
        let merge = GitLog.References(subject: "Merge pull request #99 from acme/CD-001-U5-orders-button")
        #expect(merge.pullRequest == 99)
        #expect(merge.code == "CD-001")
        #expect(merge.tasks.isEmpty)

        let work = GitLog.References(subject: "CD-005-U8: Review — show the edit button on every row (task 1234)")
        #expect(work.pullRequest == nil)
        #expect(work.code == "CD-005")
        #expect(work.label == "CD-005-U8")
        #expect(work.tasks == ["1234"])

        #expect(GitLog.References(subject: "AB-002.1-U2: managers add documents (task 5678)").code == "AB-002.1")
        #expect(GitLog.References(subject: "Fix the build (#12)").pullRequest == 12)
        #expect(GitLog.References(subject: "Status refresh: QC results").code == nil)
    }

    @Test func readsCommittersFromShortlog() {
        let output = """
           120\talexdoe <alex.doe@example.com>
            14\tAlex Personal <alex@example.org>
             3\tAlex Doe <Alex.Doe@example.com>
             1\tAcme ops <ops+bot@example.com>
        """
        let authors = GitLog.parseAuthors(output)
        #expect(authors.map(\.name) == ["alexdoe", "Alex Personal", "Acme ops"])
        #expect(authors.first?.commits == 123, "the same email in other case is one person")
        #expect(authors.last?.email == "ops+bot@example.com")
    }

    @Test func filtersCommitsByAuthors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskAuthors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        for (name, email) in [("Ann", "ann@x.io"), ("Bob", "bob+dev@x.io"), ("Cy", "cy@x.io"), ("Ann", "ann@x.io")] {
            try git("-c", "user.name=\(name)", "-c", "user.email=\(email)", "commit", "-q", "--allow-empty", "-m", "by \(name)")
        }
        #expect(GitLog.commits(in: root).count == 4)
        #expect(GitLog.commits(in: root, authors: ["ANN@x.io"]).map(\.author) == ["Ann", "Ann"])
        #expect(Set(GitLog.commits(in: root, authors: ["bob+dev@x.io", "cy@x.io"]).map(\.author)) == ["Bob", "Cy"], "a plus in the email is literal")
        #expect(GitLog.authors(in: root).map(\.name) == ["Ann", "Bob", "Cy"])
    }
}
