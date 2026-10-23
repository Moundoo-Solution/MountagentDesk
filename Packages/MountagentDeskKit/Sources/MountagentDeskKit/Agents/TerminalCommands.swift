import Foundation

/// An agent driven through its own terminal interface rather than a headless stream, as
/// for CLIs that print only plain text when headless (Kiro).
public struct TerminalAgent: Equatable, Sendable, Identifiable {
    public let name: String
    public let executable: String
    /// What a new session runs.
    public let command: String
    /// What it runs after that (the app relaunched, or Run Again): the folder's last conversation.
    public let resume: String
    /// The vendor's installer, run in the session when the CLI is missing.
    public let install: String

    public var id: String { name }
}

/// What a terminal session can run: any command line, with the agent and developer CLIs
/// found on this Mac offered first.
public enum TerminalCommands {
    public static let agents = [
        TerminalAgent(name: "Kiro", executable: "kiro-cli", command: "kiro-cli chat", resume: "kiro-cli chat --resume",
                      install: "curl -fsSL https://cli.kiro.dev/install | bash"),
    ]

    /// The terminal agent `command` starts, if any.
    public static func agent(for command: String) -> TerminalAgent? {
        let program = program(of: command)
        return agents.first { $0.executable == program }
    }

    /// The line to run: a terminal agent resumes its conversation after the first run, and
    /// is installed first when missing.
    public static func line(for command: String, hasRun: Bool, find: (String) -> URL? = ExecutableLocator.find) -> String {
        guard let agent = agent(for: command), command.trimmingCharacters(in: .whitespaces) == agent.command else { return command }
        let run = hasRun ? agent.resume : agent.command
        return find(agent.executable) == nil ? "\(agent.install) && \(run)" : run
    }
    /// Offered when installed, in this order.
    static let known = [
        "claude", "codex", "gemini", "opencode", "copilot", "cursor-agent", "agy",
        "aider", "goose", "amp", "droid", "qwen", "kimi", "crush", "cline", "plandex",
        "lazygit", "htop", "btop", "k9s",
    ]

    public static func installed(find: (String) -> URL? = ExecutableLocator.find) -> [String] {
        known.filter { find($0) != nil }
    }

    /// The session's title: the program's name (`aider` for `aider --model x`), or Shell.
    public static func title(for command: String) -> String {
        agent(for: command)?.name ?? program(of: command) ?? "Shell"
    }

    static func program(of command: String) -> String? {
        let words = command.split(whereSeparator: \.isWhitespace)
        // Skip `VAR=value` assignments in front of the program.
        guard let program = words.first(where: { !$0.contains("=") }) else { return nil }
        return (String(program) as NSString).lastPathComponent
    }
}
