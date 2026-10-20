import Foundation

/// Finds the agent CLIs. Apps started from Finder get a minimal PATH, so the login
/// shell's PATH and the usual install folders are searched as well.
public struct ExecutableLocator: Sendable {
    public var overrides: [AgentKind: String]

    public init(overrides: [AgentKind: String] = [:]) {
        self.overrides = overrides
    }

    public func locate(_ kind: AgentKind) -> URL? {
        if let override = overrides[kind]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return Self.find(kind.executableName)
    }

    public static func find(_ name: String) -> URL? {
        for directory in searchPath {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// PATH handed to child processes, so the agents can find git, node, rg and friends.
    public static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = loginShellPath()
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.cursor/bin", "\(home)/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath.joined(separator: ":")
        // Set when Mountagent Desk itself is started from inside a Claude Code session.
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return env
    }

    private static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
    }
}
