import Foundation

/// A prompt kept for reuse, picked in the composer (its menu, or `/` and a few letters).
public struct PromptTemplate: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var text: String

    public init(id: UUID = UUID(), title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }

    /// The first set, for any kind of project; users change and add their own.
    public static let defaults: [PromptTemplate] = [
        PromptTemplate(title: "Plan before changing code", text: "Before changing any code, read the relevant files and propose a plan: what you would change, where, and what could break. Wait for my go-ahead."),
        PromptTemplate(title: "Review uncommitted changes", text: "Review my uncommitted changes: point out bugs, risky edits and anything missing, such as tests or documentation."),
        PromptTemplate(title: "Explain this error", text: "Explain this error, find its cause in the code and propose a fix:\n\n"),
        PromptTemplate(title: "Add tests for the change", text: "Add tests that cover the change you just made, following the project's existing test style, and run them."),
        PromptTemplate(title: "Write a commit message", text: "Write a commit message for my uncommitted changes: a short summary line, then what changed and why."),
    ]

    /// Templates whose title has every word typed after `/`; nil unless `text` is such a
    /// command (one line starting with `/`).
    public static func matches(for text: String, in templates: [PromptTemplate]) -> [PromptTemplate]? {
        guard text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let words = text.dropFirst().lowercased().split(whereSeparator: \.isWhitespace)
        return templates.filter { template in words.allSatisfy { template.title.lowercased().contains($0) } }
    }
}
