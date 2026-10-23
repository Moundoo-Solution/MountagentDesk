import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct WorktreeSetupTests {
    @Test func runsInTheWorktreeWithBothFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        let main = root.appendingPathComponent("repo"), worktree = root.appendingPathComponent("repo.worktrees/a1")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "SECRET=1\n".write(to: main.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let result = WorktreeSetup.run(#"cp "$MOUNTAGENT_MAIN_FOLDER/.env" . && echo copied to "$MOUNTAGENT_WORKTREE""#, in: worktree, mainFolder: main)
        #expect(result.succeeded)
        #expect(result.output.contains("copied to \(worktree.path)"))
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".env").path))
    }

    @Test func reportsFailureAndTimeout() {
        let folder = FileManager.default.temporaryDirectory
        let failed = WorktreeSetup.run("echo nope >&2; exit 3", in: folder, mainFolder: folder)
        #expect(failed.status == 3 && !failed.succeeded && failed.output.contains("nope"))
        let slow = WorktreeSetup.run("sleep 5", in: folder, mainFolder: folder, timeout: 0.5)
        #expect(slow.timedOut && !slow.succeeded)
    }
}
