import Foundation

/// The files in a project that shape what the agents know: rules, skills and MCP config.
/// Mountagent Desk keeps them in each tool's own format, so they still work when the project is
/// opened in Cursor or in the `claude` terminal.
///
/// - `AGENTS.md` is read by Cursor and Codex directly, and by Claude through `@AGENTS.md`
///   in `CLAUDE.md`.
/// - `.claude/skills/<name>/SKILL.md` is read by Claude and Cursor.
public struct ProjectContext: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case shared = "All agents"
        case claude = "Claude only"
        case cursor = "Cursor only"
        case mcp = "MCP servers"

        public var id: String { rawValue }
    }

    public struct File: Identifiable, Hashable, Sendable {
        public var relativePath: String
        public var group: Group
        public var exists: Bool
        public var id: String { relativePath }
        public var name: String { (relativePath as NSString).lastPathComponent }
    }

    public struct Skill: Identifiable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var relativePath: String
        public var id: String { name }
    }

    public enum RuleTarget: String, CaseIterable, Identifiable, Sendable {
        case claude
        case cursor
        public var id: String { rawValue }
    }

    static let claudeImport = "@AGENTS.md"

    // MARK: Files

    /// Well-known files are listed even when missing so they can be created; rule folders
    /// list what is there.
    public func files() -> [File] {
        var files = [
            file("AGENTS.md", .shared),
            file("CLAUDE.md", .claude),
        ]
        files += listing(".claude/rules", extensions: ["md"], group: .claude)
        files += listing(".cursor/rules", extensions: ["mdc", "md"], group: .cursor)
        files += [file(".mcp.json", .mcp), file(".cursor/mcp.json", .mcp)]
        return files
    }

    public func read(_ relativePath: String) -> String {
        (try? String(contentsOf: url(relativePath), encoding: .utf8)) ?? ""
    }

    public func write(_ text: String, to relativePath: String) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
    }

    public func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url(relativePath))
    }

    /// Default content for a file that does not exist yet.
    public func template(for relativePath: String) -> String {
        switch relativePath {
        case "AGENTS.md":
            "# Project guide\n\nInstructions every agent should follow in this project.\n\n## Conventions\n\n- \n"
        case "CLAUDE.md":
            "\(Self.claudeImport)\n\n# Claude-only notes\n"
        case ".mcp.json", ".cursor/mcp.json":
            "{\n  \"mcpServers\": {}\n}\n"
        default:
            relativePath.hasSuffix(".mdc")
                ? "---\ndescription: \nglobs: \nalwaysApply: false\n---\n\n"
                : "# Rule\n\n"
        }
    }

    public func newRulePath(named name: String, for target: RuleTarget) -> String {
        let slug = Self.slug(name)
        return switch target {
        case .claude: ".claude/rules/\(slug).md"
        case .cursor: ".cursor/rules/\(slug).mdc"
        }
    }

    // MARK: Claude ↔ AGENTS.md

    /// Whether Claude will see AGENTS.md. Cursor always does.
    public var claudeReadsAgentsFile: Bool {
        read("CLAUDE.md").contains(Self.claudeImport)
    }

    /// Adds `@AGENTS.md` at the top of CLAUDE.md, creating it if needed.
    public func linkAgentsFileToClaude() throws {
        let current = read("CLAUDE.md")
        guard !current.contains(Self.claudeImport) else { return }
        try write(current.isEmpty ? template(for: "CLAUDE.md") : "\(Self.claudeImport)\n\n\(current)", to: "CLAUDE.md")
    }

    // MARK: Skills

    public func skills() -> [Skill] {
        let directory = url(".claude/skills")
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry -> Skill? in
            let relative = ".claude/skills/\(entry.lastPathComponent)/SKILL.md"
            guard FileManager.default.fileExists(atPath: url(relative).path) else { return nil }
            let front = Self.frontMatter(read(relative))
            return Skill(
                name: front["name"] ?? entry.lastPathComponent,
                description: front["description"] ?? "",
                relativePath: relative
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func createSkill(name: String, description: String) throws -> Skill {
        let slug = Self.slug(name)
        let relative = ".claude/skills/\(slug)/SKILL.md"
        guard !FileManager.default.fileExists(atPath: url(relative).path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let body = """
        ---
        name: \(slug)
        description: \(description.replacingOccurrences(of: "\n", with: " "))
        ---

        # \(name)

        Steps the agent should follow when this skill applies.

        """
        try write(body, to: relative)
        return Skill(name: slug, description: description, relativePath: relative)
    }

    public func deleteSkill(_ skill: Skill) throws {
        try FileManager.default.removeItem(at: url(skill.relativePath).deletingLastPathComponent())
    }

    // MARK: Helpers

    public func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private func file(_ relativePath: String, _ group: Group) -> File {
        File(relativePath: relativePath, group: group, exists: FileManager.default.fileExists(atPath: url(relativePath).path))
    }

    private func listing(_ folder: String, extensions: Set<String>, group: Group) -> [File] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: url(folder), includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { extensions.contains($0.pathExtension) }
            .map { File(relativePath: "\(folder)/\($0.lastPathComponent)", group: group, exists: true) }
            .sorted { $0.relativePath < $1.relativePath }
    }

    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let folded = name.lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .folding(options: .diacriticInsensitive, locale: nil)
        let slug = folded.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "untitled" : slug
    }

    /// Reads `key: value` lines from a leading `---` block.
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return values
    }
}
