import Foundation

/// JSON files under Application Support:
///
///     projects.json
///     sessions/<project id>/<session id>.json
///     usage.json, plan-usage.json, cursor-usage.json, git-accounts.json   (app state)
///
/// Writes are atomic, so a crash never leaves a half-written file. A file that no longer
/// decodes is set aside (`*.corrupt-<date>`) rather than skipped or overwritten, and deleted
/// sessions go to the Trash.
public final class ProjectStore: @unchecked Sendable {
    public let root: URL
    /// Deleted sessions go to the Trash (off for scratch stores in tests).
    private let trashesDeleted: Bool
    private let fileManager = FileManager.default
    /// Compact: sessions with long tool output run to megabytes, and pretty-printing them
    /// costs more than it helps.
    private let encoder = JSONEncoder()
    /// Session saves, in order, off the main thread.
    private let writes = DispatchQueue(label: "Mountagent Desk session writes", qos: .utility)
    private let decoder = JSONDecoder()

    public init(root: URL, trashesDeleted: Bool = true) {
        self.root = root
        self.trashesDeleted = trashesDeleted
    }

    /// `MOUNTAGENT_DATA_DIR` points a debug build at a scratch store. Release builds ignore
    /// it: an agent could otherwise run the app's own executable on a store it wrote itself.
    public static func defaultRoot() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MOUNTAGENT_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return standardRoot
    }

    static let standardRoot: URL = {
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
        try remove(sessionsDirectory(projectID))
    }

    /// Copies a file that no longer decodes to `<name>.corrupt-<date>`, so a later save can't
    /// lose what was in it; returns the copy. `moving` takes the original away as well.
    @discardableResult
    public func setAside(_ file: URL, moving: Bool = false) -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let copy = file.deletingPathExtension().appendingPathExtension("corrupt-\(stamp)")
        do {
            if moving { try fileManager.moveItem(at: file, to: copy) } else { try fileManager.copyItem(at: file, to: copy) }
            return copy
        } catch {
            return nil
        }
    }

    public var projectsFileURL: URL { projectsFile }

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

    /// Newest first.
    public func loadSessions(of projectID: UUID) -> [ChatSession] {
        loadSessionsSettingAsideDamage(of: projectID).sessions
    }

    /// Newest first. A file that fails to decode doesn't fail the list: it is moved aside
    /// (`*.corrupt-<date>`) and returned, so the user can be told.
    public func loadSessionsSettingAsideDamage(of projectID: UUID) -> (sessions: [ChatSession], setAside: [URL]) {
        let directory = sessionsDirectory(projectID)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        // Decoded side by side: a project's sessions can add up to many megabytes.
        let decoded = UnsafeMutableBufferPointer<ChatSession?>.allocate(capacity: jsonFiles.count)
        decoded.initialize(repeating: nil)
        defer { decoded.deallocate() }
        DispatchQueue.concurrentPerform(iterations: jsonFiles.count) { index in
            decoded[index] = try? JSONDecoder().decode(ChatSession.self, from: Data(contentsOf: jsonFiles[index]))
        }
        var sessions: [ChatSession] = []
        var setAside: [URL] = []
        for (index, file) in jsonFiles.enumerated() {
            if let session = decoded[index] {
                sessions.append(session)
            } else if let copy = self.setAside(file, moving: true) {
                setAside.append(copy)
            }
        }
        return (sessions.sorted { $0.updatedAt > $1.updatedAt }, setAside)
    }

    public func save(_ session: ChatSession) throws {
        try write(session, to: sessionFile(session))
    }

    /// Saves on a background queue, in the order asked; `failed` runs there on an error.
    public func saveLater(_ session: ChatSession, failed: @escaping @Sendable (any Error) -> Void) {
        let file = sessionFile(session)
        writes.async { [self] in
            do { try write(session, to: file) } catch { failed(error) }
        }
    }

    /// Waits for the saves already asked for (on quit).
    public func finishWrites() {
        writes.sync {}
    }

    public func delete(_ session: ChatSession) throws {
        try remove(sessionFile(session))
    }

    /// To the Trash when it can (so a slip can be undone in Finder), else gone.
    private func remove(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if trashesDeleted, (try? fileManager.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        try fileManager.removeItem(at: url)
    }

    private func write(_ value: some Encodable, to file: URL) throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
