import Foundation

/// The title and description a new pull request starts with: the session's title, what
/// the agent last said it did, and the branch's commits.
public enum PullRequestDraft {
    /// Branch names a pull request isn't opened from.
    public static let mainBranches: Set<String> = ["main", "master", "develop", "trunk"]

    public static func title(session: String, branch: String) -> String {
        let named = session.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty, named != "New session" { return named }
        // mountagent/offline-maps-3f9a2c1d → Offline maps
        var words = (branch.split(separator: "/").last.map(String.init) ?? branch)
            .replacingOccurrences(of: #"-[0-9a-f]{8}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let first = words.first { words = first.uppercased() + words.dropFirst() }
        return words
    }

    public static func body(summary: String?, commits: [String]) -> String {
        var parts: [String] = []
        if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            // The reply's first paragraph: what was done, not the whole explanation.
            let first = summary.components(separatedBy: "\n\n").first ?? summary
            parts.append("## Summary\n\n" + String(first.prefix(1_200)))
        }
        if !commits.isEmpty {
            parts.append("## Commits\n\n" + commits.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
