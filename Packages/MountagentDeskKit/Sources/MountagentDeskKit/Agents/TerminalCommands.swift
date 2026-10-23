import Foundation

/// What a terminal session can run: any command line, with the agent and developer CLIs
/// found on this Mac offered first.
public enum TerminalCommands {
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
        let words = command.split(whereSeparator: \.isWhitespace)
        // Skip `VAR=value` assignments in front of the program.
        guard let program = words.first(where: { !$0.contains("=") }) else { return "Shell" }
        return (String(program) as NSString).lastPathComponent
    }
}
