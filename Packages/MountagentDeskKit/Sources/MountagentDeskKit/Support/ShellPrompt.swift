import Foundation

/// A colored zsh prompt with the git branch, for the app's own terminals only. zsh starts
/// with `ZDOTDIR` pointing at files the app writes; each one loads the user's own file of
/// the same name first (from their `ZDOTDIR`, or home), so their setup behaves as in any
/// terminal. The prompt is only set when theirs is still macOS's plain default.
public enum ShellPrompt {
    /// The user's own `ZDOTDIR` (or home), handed to the app's startup files.
    public static let userDirectoryVariable = "MOUNTAGENT_USER_ZDOTDIR"

    /// Writes the startup files under `root/shell/zsh`; returns that folder for `ZDOTDIR`.
    @discardableResult
    public static func install(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("shell/zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, text) in files {
            let file = directory.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        return directory
    }

    /// Environment for a zsh started in an app terminal.
    public static func environment(zdotdir: URL, current: [String: String]) -> [String: String] {
        let home = current["HOME"] ?? NSHomeDirectory()
        let own = current["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home
        return ["ZDOTDIR": zdotdir.path, userDirectoryVariable: own]
    }

    static let files: [(String, String)] = [
        (".zshenv", load(".zshenv")),
        (".zprofile", load(".zprofile")),
        (".zshrc", """
        # Mountagent Desk: macOS's /etc/zshrc put history next to these files; keep it the user's.
        [[ $HISTFILE == ${ZDOTDIR}/* ]] && HISTFILE="$\(userDirectoryVariable)/.zsh_history"
        \(load(".zshrc", restore: false))
        # The user's own folder from here on (zsh reads .zlogin from it next).
        ZDOTDIR="$\(userDirectoryVariable)"
        # Only replace macOS's plain default prompt.
        if [[ -z $PROMPT || $PROMPT == '%n@%m %1~ %# ' ]]; then
          autoload -Uz vcs_info
          zstyle ':vcs_info:git:*' formats ' %F{yellow}(%b)%f'
          zstyle ':vcs_info:git:*' actionformats ' %F{yellow}(%b|%a)%f'
          _mountagent_vcs_info() { vcs_info }
          precmd_functions+=(_mountagent_vcs_info)
          setopt prompt_subst
          PROMPT='%F{green}%n@%m%f %F{blue}%1~%f${vcs_info_msg_0_} %(?.%F{magenta}.%F{red})%#%f '
        fi

        """),
    ]

    /// Sources the user's file of that name, with `ZDOTDIR` set as their file expects.
    private static func load(_ name: String, restore: Bool = true) -> String {
        """
        # Mountagent Desk: load the user's own \(name) first.
        _mountagent_zdotdir=$ZDOTDIR
        ZDOTDIR="$\(userDirectoryVariable)"
        [[ -f "$ZDOTDIR/\(name)" ]] && source "$ZDOTDIR/\(name)"
        \(userDirectoryVariable)="$ZDOTDIR"
        \(restore ? "ZDOTDIR=$_mountagent_zdotdir\n" : "")unset _mountagent_zdotdir

        """
    }
}
