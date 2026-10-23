import Foundation

/// `mountagent-server`, the only way agents reach servers. The app writes a small script of
/// that name that runs the app's own executable with `--server-exec`. That helper only
/// passes the request to the running app (`ServerBroker`), with the token the app gave this
/// agent run; the app then:
///
/// 1. finds the run's project from the token (never from anything the agent can set),
/// 2. refuses servers not linked to it or without agent access, which the app keeps in the
///    keychain, not in servers.json,
/// 3. refuses commands that aren't read-only (`ServerCommandPolicy`),
/// 4. runs the command over ssh itself (`ServerRun`), and logs it to `server-audit.log`.
public enum ServerHelper {
    public static let commandName = "mountagent-server"
    /// The app's executable takes this as its first argument to act as the helper.
    public static let flag = "--server-exec"
    static let auditLogName = "server-audit.log"

    /// Programs that reach servers, and the ways a command line can name them.
    static let remoteTools = ["ssh", "scp", "sftp", "rsync"]

    /// Claude's `Bash(…)` deny rules match the command's start: `/usr/bin/ssh` or `env ssh`
    /// would get past a rule for plain `ssh`.
    public static var claudeDenyRules: String {
        remoteTools.flatMap { tool in ["", "/usr/bin/", "env ", "command ", "exec ", "nohup "].map { "Bash(\($0)\(tool):*)" } }.joined(separator: ",")
    }

    /// Copilot matches the program's name, so the full path needs a rule of its own.
    public static var copilotDenyRules: [String] {
        remoteTools.flatMap { ["--deny-tool=shell(\($0):*)", "--deny-tool=shell(/usr/bin/\($0):*)"] }
    }

    /// The app's own executable, which answers ssh's password prompt when started with the
    /// askpass variable set.
    public static var askpassExecutable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// The script agents run.
    public static func wrapper(in root: URL) -> URL {
        root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(commandName)
    }

    /// Writes `bin/mountagent-server` under the store; returns the folder to put on PATH.
    @discardableResult
    public static func installWrapper(executable: String, in root: URL) throws -> URL {
        let file = wrapper(in: root)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nexec \(Shell.quote(executable)) \(flag) \"$@\"\n"
        if (try? String(contentsOf: file, encoding: .utf8)) != script {
            try script.write(to: file, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return directory
    }

    /// The servers an agent working in `project` may read.
    public static func readable(in project: Project, servers: [Server]) -> [Server] {
        servers.filter { project.serverIDs.contains($0.id) && $0.aiReadAccess }
    }

    /// Told to the agent with each message while it can read servers.
    public static func note(for servers: [Server]) -> String {
        let list = servers.map { "- \($0.handle): \($0.name) (\($0.host))" }.joined(separator: "\n")
        return """
        You may read these servers, and only through Mountagent Desk:
        \(list)
        Run `\(commandName) <server> '<command>'` with one shell command line, e.g. \
        `\(commandName) \(servers.first?.handle ?? "live") 'journalctl -n 200 --no-pager'`. \
        `\(commandName) list` shows them. Only read-only commands pass: cat, head, tail -n, grep, ls, find, \
        ps, df, free, du, journalctl, systemctl status, docker ps/logs, git log/status/diff, and \
        psql -c "SELECT …" (run in a read-only transaction). Anything that changes files, services, \
        packages or data is refused. Never run ssh, scp or rsync to a server yourself; if a change is \
        needed on a server, tell the user the exact commands and let them run them.
        """
    }

    // MARK: Deciding (in the app)

    public enum Decision: Equatable {
        case reply(ServerBroker.Reply)
        /// Run this read-only command on the server.
        case run(Server, command: String)
    }

    /// What to do with a helper's request from a run of `project` (`nil`: the token is
    /// unknown or its run has ended). `servers` are the app's own, agent access included.
    public static func decide(_ request: ServerBroker.Request, project: Project?, servers: [Server], log: (Server, String, String) -> Void = { _, _, _ in }) -> Decision {
        guard let project else {
            return .reply(.refused("\(commandName) only works for agents while Mountagent Desk runs their turn."))
        }
        let linked = servers.filter { project.serverIDs.contains($0.id) }
        guard let name = request.server else {
            let lines = linked.map { "\($0.handle)\t\($0.name)\t\($0.aiReadAccess ? "readable" : "agent access off")\n" }
            return .reply(ServerBroker.Reply(output: lines.isEmpty ? "No servers are linked to \(project.name).\n" : lines.joined(), status: 0))
        }
        guard let server = linked.first(where: { $0.handle == name.lowercased() || $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.host == name }) else {
            let known = linked.map(\.handle).joined(separator: ", ")
            return .reply(.refused("No server named \(name) in \(project.name)." + (known.isEmpty ? "" : " Linked servers: \(known).")))
        }
        guard server.aiReadAccess else {
            log(server, request.command, "refused: agent access off")
            return .reply(.refused("Agent access to \(server.name) is off. Ask the user to turn it on in Mountagent Desk's Servers panel."))
        }
        switch ServerCommandPolicy.check(request.command, sudoUsers: server.agentSudoUsers) {
        case .blocked(let reason):
            log(server, request.command, "refused: \(reason)")
            return .reply(.refused("Refused, \(server.name) is read-only for agents: \(reason)"))
        case .allowed(let safe):
            log(server, safe, "ran")
            return .run(server, command: safe)
        }
    }

    /// Appends one line to `server-audit.log`.
    public static func audit(root: URL, project: String, server: String, command: String, outcome: String) {
        let line = [ISO8601DateFormatter().string(from: .now), project, server, outcome, command]
            .map { $0.replacingOccurrences(of: "\t", with: " ") }
            .joined(separator: "\t") + "\n"
        let file = root.appendingPathComponent(auditLogName)
        if let handle = try? FileHandle(forWritingTo: file) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    // MARK: Running as the helper

    /// Runs the helper with the arguments after `--server-exec`; returns its exit status.
    public static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        if let account = environment[ServerPasswords.askpassVariable] {
            return ServerPasswords.answerAskpass(account: account, prompt: arguments.joined(separator: " "))
        }
        guard let name = arguments.first, !name.isEmpty, name != "-h", name != "--help" else {
            print("usage: \(commandName) <server> '<read-only command>'\n       \(commandName) list")
            return 2
        }
        guard let token = environment[ServerBroker.tokenVariable], !token.isEmpty else {
            return fail("\(commandName) only works for agents started by Mountagent Desk.")
        }
        let request = ServerBroker.Request(token: token, server: name == "list" ? nil : name, command: arguments.dropFirst().joined(separator: " "))
        let reply: ServerBroker.Reply
        do {
            reply = try ServerBroker.send(request, root: ProjectStore.defaultRoot())
        } catch {
            return fail("Mountagent Desk isn't running, so servers can't be reached.")
        }
        FileHandle.standardOutput.write(Data(reply.output.utf8))
        if let error = reply.error { FileHandle.standardError.write(Data("\(commandName): \(error)\n".utf8)) }
        return reply.status
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("\(commandName): \(message)\n".utf8))
        return 1
    }
}
