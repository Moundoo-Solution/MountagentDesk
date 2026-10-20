import Foundation

/// Reads and edits the allow list in a project's `.cursor/cli.json`, which cursor-agent
/// merges with `~/.cursor/cli-config.json`. Other keys in the file are kept as they are.
public enum CursorPermissions {
    public static let relativePath = ".cursor/cli.json"

    public static func allowedRules(in root: URL) -> [String] {
        let permissions = read(root)["permissions"] as? JSONObject
        return permissions?["allow"] as? [String] ?? []
    }

    /// Adds a rule; returns false when it was already there.
    @discardableResult
    public static func allow(_ rule: String, in root: URL) throws -> Bool {
        var allowed = allowedRules(in: root)
        guard !allowed.contains(rule) else { return false }
        allowed.append(rule)
        try write(allowed, in: root)
        return true
    }

    public static func revoke(_ rule: String, in root: URL) throws {
        let allowed = allowedRules(in: root)
        guard allowed.contains(rule) else { return }
        try write(allowed.filter { $0 != rule }, in: root)
    }

    private static func file(_ root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }

    private static func read(_ root: URL) -> JSONObject {
        guard let data = try? Data(contentsOf: file(root)),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else { return [:] }
        return object
    }

    private static func write(_ allowed: [String], in root: URL) throws {
        var object = read(root)
        var permissions = object["permissions"] as? JSONObject ?? [:]
        permissions["allow"] = allowed
        if permissions["deny"] == nil { permissions["deny"] = [String]() }
        object["permissions"] = permissions
        // Don't leave behind a file that only says "nothing allowed" (e.g. after a one-off retry).
        if object.count == 1, allowed.isEmpty, (permissions["deny"] as? [String])?.isEmpty ?? true, permissions.count <= 2 {
            try? FileManager.default.removeItem(at: file(root))
            return
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let target = file(root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}
