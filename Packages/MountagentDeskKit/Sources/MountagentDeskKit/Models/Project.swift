import Foundation

/// A set of folders the agents work in. The primary folder is the working directory and
/// holds the project's rules and skills; additional folders are passed with `--add-dir`.
/// Sessions belong to exactly one project.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var additionalPaths: [String]
    /// Also load the rules (CLAUDE.md / AGENTS.md) found in the additional folders.
    public var loadsAdditionalRules: Bool
    /// The git account written into this project's repositories, if one was chosen.
    public var gitAccountID: UUID?
    /// Servers this project deploys to; their terminals open in its Servers panel.
    public var serverIDs: [UUID] = []
    public var createdAt: Date
    public var defaultAgent: AgentKind

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        additionalPaths: [String] = [],
        loadsAdditionalRules: Bool = false,
        createdAt: Date = .now,
        defaultAgent: AgentKind = .claude
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.additionalPaths = additionalPaths
        self.loadsAdditionalRules = loadsAdditionalRules
        self.createdAt = createdAt
        self.defaultAgent = defaultAgent
    }

    // Projects saved before multi-folder support have no additional folders.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        additionalPaths = try container.decodeIfPresent([String].self, forKey: .additionalPaths) ?? []
        loadsAdditionalRules = try container.decodeIfPresent(Bool.self, forKey: .loadsAdditionalRules) ?? false
        gitAccountID = try container.decodeIfPresent(UUID.self, forKey: .gitAccountID)
        serverIDs = try container.decodeIfPresent([UUID].self, forKey: .serverIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        defaultAgent = try container.decode(AgentKind.self, forKey: .defaultAgent)
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public var additionalURLs: [URL] {
        additionalPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Primary folder first.
    public var allPaths: [String] { [path] + additionalPaths }

    public var exists: Bool { Self.isDirectory(path) }

    public var missingPaths: [String] {
        allPaths.filter { !Self.isDirectory($0) }
    }

    /// Makes another folder of the project the primary one; the old primary becomes additional.
    public mutating func makePrimary(_ newPrimary: String) {
        guard newPrimary != path, let index = additionalPaths.firstIndex(of: newPrimary) else { return }
        additionalPaths[index] = path
        path = newPrimary
    }

    /// Adds folders that aren't in the project yet; returns how many were added.
    @discardableResult
    public mutating func addFolders(_ paths: [String]) -> Int {
        let new = paths.filter { !allPaths.contains($0) }
        var seen = Set<String>()
        additionalPaths += new.filter { seen.insert($0).inserted }
        return seen.count
    }

    /// Shows a path relative to the folder that contains it: the primary folder's files
    /// bare, an additional folder's files prefixed with that folder's name.
    public func displayPath(_ text: String) -> String {
        var result = text
        // Longest first, so a folder nested in another resolves to the inner one.
        for folder in allPaths.sorted(by: { $0.count > $1.count }) {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            let replacement = folder == path ? "" : (folder as NSString).lastPathComponent + "/"
            result = result.replacingOccurrences(of: prefix, with: replacement)
        }
        return result
    }

    /// The path to hand an agent for a file: relative inside the primary folder, absolute elsewhere.
    public func agentPath(for fileURL: URL) -> String {
        let file = fileURL.standardizedFileURL.path
        let root = url.standardizedFileURL.path + "/"
        return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
