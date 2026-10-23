import Foundation

/// A session as Markdown, to paste into a ticket or a task note: the conversation, the
/// tools the agent ran (their output folded and cut short), and the app's notices.
public enum SessionExport {
    static let outputLimit = 4000

    public static func markdown(_ session: ChatSession, projectName: String? = nil) -> String {
        var lines = ["# \(session.title)", ""]
        let when = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        lines.append("_\([projectName, session.agent.displayName, when].compactMap { $0 }.joined(separator: " · "))_")
        for item in session.items {
            lines.append("")
            switch item.kind {
            case .user:
                lines.append("**You:**")
                lines.append("")
                lines.append(item.text)
                if !item.attachments.isEmpty { lines.append("") ; lines.append("Attached: " + item.attachments.map { "`\($0)`" }.joined(separator: ", ")) }
            case .assistant:
                lines.append("**\((item.agent ?? session.agent).displayName):**")
                lines.append("")
                lines.append(SessionTitle.extract(from: item.text).text)
            case .thinking:
                lines.removeLast()
            case .tool:
                let status = item.toolStatus == .failed ? " (failed)" : ""
                lines.append("- `\(item.toolName ?? "tool")` \(item.text)\(status)")
                if let output = item.toolOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                    let shown = output.count > outputLimit ? String(output.prefix(outputLimit)) + "\n…" : output
                    lines.append("")
                    lines.append("  <details><summary>Output</summary>")
                    lines.append("")
                    lines.append(fence(shown, indent: "  "))
                    lines.append("")
                    lines.append("  </details>")
                }
            case .permission:
                let state = item.permissionState.map { " — \($0.rawValue)" } ?? ""
                lines.append("- Asked to use `\(item.toolName ?? "tool")`: \(item.text)\(state)")
            case .notice:
                lines.append("> \(item.isError ? "⚠️ " : "")\(item.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A code fence long enough not to end inside `text`.
    private static func fence(_ text: String, indent: String) -> String {
        var marks = "```"
        while text.contains(marks) { marks += "`" }
        let body = text.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
        return "\(indent)\(marks)\n\(body)\n\(indent)\(marks)"
    }

    /// A file name from the title: letters, digits and dashes.
    public static func fileName(for session: ChatSession) -> String {
        let slug = session.title.folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (slug.isEmpty ? "session" : String(slug.prefix(80))) + ".md"
    }
}
