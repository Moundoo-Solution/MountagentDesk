import Foundation

/// JSON files under Application Support:
///
///     projects.json
///     sessions/<project id>/<session id>.json
///     usage.json, plan-usage.json, cursor-usage.json, git-accounts.json   (app state)
///
/// Writes are atomic, so a crash never leaves a half-written file.
public final class ProjectStore: @unchecked Sendable {
    public let root: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    public init(root: URL) {
        self.root = root
    }

    /// `MOUNTAGENT_DATA_DIR` points the app at a scratch store for development.
    public static func defaultRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["MOUNTAGENT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return standardRoot
    }

    private static let standardRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Mountagent Desk", isDirectory: true)
        moveLegacyData(from: support.appendingPathComponent("AgentDesk", isDirectory: true), to: root)
        return root
    }()

    /// Moves the data of the app's former name (AgentDesk) to `root` the first time, and
    /// leaves a link at the old path so file paths saved in sessions keep resolving.
    static func moveLegacyData(from legacy: URL, to root: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: root.path), fileManager.fileExists(atPath: legacy.path) else { return }
        do {
            try fileManager.moveItem(at: legacy, to: root)
            try fileManager.createSymbolicLink(at: legacy, withDestinationURL: root)
        } catch {
            // Starting with an empty store beats not starting; the old folder is left as it was.
        }
    }

    private var projectsFile: URL { root.appendingPathComponent("projects.json") }

    private func sessionsDirectory(_ projectID: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func sessionFile(_ session: ChatSession) -> URL {
        sessionsDirectory(session.projectID).appendingPathComponent("\(session.id.uuidString).json")
    }

    // MARK: Projects

    public func loadProjects() throws -> [Project] {
        guard fileManager.fileExists(atPath: projectsFile.path) else { return [] }
        return try decoder.decode([Project].self, from: Data(contentsOf: projectsFile))
    }

    public func saveProjects(_ projects: [Project]) throws {
        try write(projects, to: projectsFile)
    }

    public func deleteSessions(of projectID: UUID) throws {
        let directory = sessionsDirectory(projectID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    // MARK: App state

    /// Small app-wide values (usage ledger, last plan limits) in their own JSON files.
    public func load<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        let file = root.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    public func save(_ value: some Encodable, named name: String) throws {
        try write(value, to: root.appendingPathComponent("\(name).json"))
    }

    // MARK: Sessions

    /// Newest first. Files that fail to decode are skipped rather than failing the whole list.
    public func loadSessions(of projectID: UUID) -> [ChatSession] {
        let directory = sessionsDirectory(projectID)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ChatSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ session: ChatSession) throws {
        try write(session, to: sessionFile(session))
    }

    public func delete(_ session: ChatSession) throws {
        let file = sessionFile(session)
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    private func write(_ value: some Encodable, to file: URL) throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
