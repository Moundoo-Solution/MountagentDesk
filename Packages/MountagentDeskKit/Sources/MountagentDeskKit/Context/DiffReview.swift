import Foundation

/// A diff's lines with their numbers, and the comments a reviewer leaves on them, which go
/// to the agent as one message.
public enum DiffReview {
    public struct Line: Equatable, Sendable {
        public enum Kind: Sendable { case hunk, added, removed, context }

        public var kind: Kind
        public var text: String
        /// In the old file (removed and context lines).
        public var oldNumber: Int?
        /// In the new file (added and context lines).
        public var newNumber: Int?
    }

    public struct Comment: Equatable, Sendable, Identifiable {
        public var id = UUID()
        public var path: String
        public var line: Int
        /// On a removed line: `line` is in the old file.
        public var removed: Bool
        public var code: String
        public var text: String

        public init(path: String, line: Int, removed: Bool, code: String, text: String) {
            self.path = path
            self.line = line
            self.removed = removed
            self.code = code
            self.text = text
        }
    }

    /// The hunks of a unified diff; git's file headers before the first `@@` are left out.
    public static func lines(of diff: String) -> [Line] {
        var result: [Line] = []
        var old = 0, new = 0
        var inHunk = false
        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                inHunk = true
                // @@ -12,7 +12,9 @@
                let numbers = raw.split(separator: " ").dropFirst().prefix(2).map { part in
                    Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                old = numbers.first ?? 0
                new = numbers.count > 1 ? numbers[1] : 0
                result.append(Line(kind: .hunk, text: raw))
                continue
            }
            guard inHunk else { continue }
            if raw.hasPrefix("+") {
                result.append(Line(kind: .added, text: raw, newNumber: new))
                new += 1
            } else if raw.hasPrefix("-") {
                result.append(Line(kind: .removed, text: raw, oldNumber: old))
                old += 1
            } else if raw.hasPrefix("\\") {
                // "\ No newline at end of file"
                result.append(Line(kind: .context, text: raw))
            } else {
                result.append(Line(kind: .context, text: raw, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        // The diff's last newline leaves an empty "line" that isn't part of the file.
        if let last = result.last, last.kind == .context, last.text.isEmpty { result.removeLast() }
        return result
    }

    /// One message for the agent, comments grouped by file in line order.
    public static func message(for comments: [Comment]) -> String {
        let files = Dictionary(grouping: comments, by: \.path).sorted { $0.key < $1.key }
        var parts = ["Review comments on your uncommitted changes. Address each one:"]
        for (path, notes) in files {
            parts.append("")
            parts.append("`\(path)`")
            for note in notes.sorted(by: { ($0.line, $0.removed ? 0 : 1) < ($1.line, $1.removed ? 0 : 1) }) {
                let place = note.removed ? "removed line \(note.line)" : "line \(note.line)"
                let code = note.code.dropFirst().trimmingCharacters(in: .whitespaces)
                parts.append("- \(place)" + (code.isEmpty ? "" : " (`\(code.prefix(120))`)") + ": \(note.text)")
            }
        }
        return parts.joined(separator: "\n")
    }
}
