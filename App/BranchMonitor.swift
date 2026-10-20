import MountagentDeskKit
import Foundation
import Observation

/// Keeps the checked-out branch of every project folder current. Each folder's git
/// directory is watched, so a checkout from anywhere (an agent, Sourcetree, Cursor, a
/// terminal) shows up at once; HEAD itself is a small file read, no `git` process.
@MainActor
@Observable
final class BranchMonitor {
    /// Folder path → branch (or short commit when detached).
    private(set) var branches: [String: String] = [:]
    /// Folder path → a counter bumped (at most every ~1.5s) whenever the repository changes:
    /// commits, checkouts, fetches. Views reload their git data when it moves.
    private(set) var revisions: [String: Int] = [:]
    @ObservationIgnored private var sources: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var pendingBumps: Set<String> = []

    func branch(of path: String) -> String? {
        branches[path]
    }

    /// Watches exactly these folders, starting and stopping watchers as needed.
    func watch(_ paths: [String]) {
        let wanted = Set(paths)
        for (path, source) in sources where !wanted.contains(path) {
            source.cancel()
            sources[path] = nil
            branches[path] = nil
        }
        for path in wanted where sources[path] == nil {
            start(path)
        }
    }

    func refresh(_ path: String) {
        let branch = GitHead.branch(of: URL(fileURLWithPath: path))
        if branches[path] != branch { branches[path] = branch }
    }

    func revision(of path: String) -> Int {
        revisions[path] ?? 0
    }

    /// Coalesces bursts (a commit touches many files under .git) into one bump.
    private func scheduleBump(_ path: String) {
        guard pendingBumps.insert(path).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingBumps.remove(path)
                self.revisions[path, default: 0] += 1
            }
        }
    }

    private func start(_ path: String) {
        refresh(path)
        guard let directory = GitHead.gitDirectory(of: URL(fileURLWithPath: path)) else { return }
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        // Git rewrites HEAD by renaming HEAD.lock over it, which is a write to the directory.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh(path)
                self?.scheduleBump(path)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[path] = source
    }
}
