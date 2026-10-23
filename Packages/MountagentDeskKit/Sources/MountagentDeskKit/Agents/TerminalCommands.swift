import Foundation

/// An agent driven through its own terminal interface rather than a headless stream, as
/// SpaceVibe Deck runs them: CLIs that print only plain text when headless (Kiro), or whose
/// headless output nobody here has read yet.
public struct TerminalAgent: Equatable, Sendable, Identifiable {
    public let name: String
    /// Who makes it.
    public let vendor: String
    public let executable: String
    /// What a new session runs.
    public let command: String
    /// What it runs after that (the app relaunched, or Run Again): the folder's last conversation.
    public let resume: String
    /// The vendor's installer, run in the session when the CLI is missing.
    public let install: String
    public let website: URL

    public var id: String { name }

    init(name: String, vendor: String, executable: String, command: String? = nil, resume: String? = nil, install: String, website: String) {
        self.name = name
        self.vendor = vendor
        self.executable = executable
        self.command = command ?? executable
        // Most are started bare again: they keep no per-folder "last conversation" flag we know of.
        self.resume = resume ?? self.command
        self.install = install
        self.website = URL(string: website)!
    }
}

/// What a terminal session can run: any command line, with the agent and developer CLIs
/// found on this Mac offered first.
public enum TerminalCommands {
    /// The vendors' own install commands, as SpaceVibe Deck checked them (2026-10-10).
    public static let agents = [
        TerminalAgent(name: "Kiro", vendor: "Amazon", executable: "kiro-cli", command: "kiro-cli chat", resume: "kiro-cli chat --resume",
                      install: "curl -fsSL https://cli.kiro.dev/install | bash", website: "https://kiro.dev/cli"),
        TerminalAgent(name: "Amp", vendor: "Sourcegraph", executable: "amp",
                      install: "curl -fsSL https://ampcode.com/install.sh | bash", website: "https://ampcode.com"),
        TerminalAgent(name: "Kimi Code", vendor: "Moonshot AI", executable: "kimi",
                      install: "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash", website: "https://www.kimi.com/code"),
        TerminalAgent(name: "Grok Build", vendor: "xAI", executable: "grok",
                      install: "curl -fsSL https://x.ai/cli/install.sh | bash", website: "https://x.ai/cli"),
        TerminalAgent(name: "Mistral Vibe", vendor: "Mistral AI", executable: "vibe",
                      install: "curl -LsSf https://mistral.ai/vibe/install.sh | bash", website: "https://docs.mistral.ai/vibe/code/cli/"),
        // `--last` is per working folder, which is what a session's terminal has.
        TerminalAgent(name: "Droid", vendor: "Factory", executable: "droid", resume: "droid --resume --last",
                      install: "curl -fsSL https://app.factory.ai/cli | sh", website: "https://docs.factory.ai/cli/getting-started/overview"),
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
        "aider", "goose", "qwen", "crush", "cline", "plandex",
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
