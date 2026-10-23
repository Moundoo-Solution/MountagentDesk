import Foundation

/// Finds sessions by title, project and what was said in them, for the ⌘K switcher.
public enum SessionSearch {
    public struct Result: Identifiable, Equatable, Sendable {
        public let sessionID: UUID
        public let title: String
        public let project: String
        public let archived: Bool
        /// Where the words were found in the conversation, if not in the title.
        public let snippet: String?
        public let updatedAt: Date
        public var id: UUID { sessionID }
    }

    /// Best first: title matches, then project matches, then text matches, newest first
    /// within each. An empty query lists the most recent sessions.
    public static func results(for query: String, in sessions: [ChatSession], projects: [UUID: String], limit: Int = 50) -> [Result] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(score: Int, result: Result)] = []
        for session in sessions {
            let project = projects[session.projectID] ?? ""
            func result(_ snippet: String?) -> Result {
                Result(sessionID: session.id, title: session.title, project: project, archived: session.archived, snippet: snippet, updatedAt: session.updatedAt)
            }
            guard !words.isEmpty else {
                scored.append((0, result(nil)))
                continue
            }
            let title = session.title.lowercased()
            let name = project.lowercased()
            if words.allSatisfy({ title.contains($0) || name.contains($0) }) {
                scored.append((words.allSatisfy(title.contains) ? 3 : 2, result(nil)))
            } else if let item = session.items.last(where: { item in
                (item.kind == .user || item.kind == .assistant) && words.allSatisfy { item.text.lowercased().contains($0) }
            }) {
                scored.append((1, result(snippet(of: item.text, around: words[0]))))
            }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.result.updatedAt > $1.result.updatedAt }
            .prefix(limit)
            .map(\.result)
    }

    /// About 90 characters of `text` around the first `word`, on one line.
    static func snippet(of text: String, around word: String) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard let range = flat.range(of: word, options: .caseInsensitive) else { return String(flat.prefix(90)) }
        let start = flat.index(range.lowerBound, offsetBy: -30, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}
