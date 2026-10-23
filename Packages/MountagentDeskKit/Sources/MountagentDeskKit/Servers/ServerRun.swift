import Darwin
import Foundation

/// Runs an agent's read-only command over ssh, in the app's own process. ssh gets a
/// pseudo-terminal of its own for its questions, and a saved password is typed at its
/// prompt: it never goes through askpass, whose environment every program ssh starts would
/// see too. The command's output comes back on a separate pipe, so nothing the server prints
/// can pass for ssh's password prompt.
public enum ServerRun {
    public static let timeout: TimeInterval = 60
    static let outputLimit = 1 << 20

    public static func ssh(_ arguments: [String], password: String?, executable: String = "/usr/bin/ssh", timeout: TimeInterval = timeout) -> ServerBroker.Reply {
        var environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(NSHomeDirectory())", "TERM=dumb", "LANG=en_US.UTF-8"]
        // The user's ssh-agent keys still work.
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment.append("SSH_AUTH_SOCK=\(agent)") }
        // C strings before fork: the child only rewires its output and execs.
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { return .refused("Couldn't start ssh.") }
        // Not inherited by other processes the app starts meanwhile: one holding the write
        // end would keep the output from ever ending.
        pipeEnds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        var master: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 250, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &size)
        if pid == 0 {
            // Signals as a fresh process has them: blocked or ignored ones in the app's
            // thread would carry over through exec (ssh's timers, a broken pipe).
            var none = sigset_t()
            sigemptyset(&none)
            sigprocmask(SIG_SETMASK, &none, nil)
            for signalNumber in [SIGPIPE, SIGALRM, SIGINT, SIGTERM, SIGHUP, SIGCHLD, SIGQUIT] { signal(signalNumber, SIG_DFL) }
            // stdout and stderr to the pipe; the terminal keeps only ssh's own questions.
            dup2(pipeEnds[1], STDOUT_FILENO)
            dup2(pipeEnds[1], STDERR_FILENO)
            close(pipeEnds[0])
            close(pipeEnds[1])
            execve(executable, argv, envp)
            _exit(127)
        }
        close(pipeEnds[1])
        if master >= 0 { _ = fcntl(master, F_SETFD, FD_CLOEXEC) }
        let outputEnd = pipeEnds[0]
        guard pid > 0 else {
            close(outputEnd)
            return .refused("Couldn't start ssh.")
        }

        var output = Data()
        var terminal = ""
        var typed = false
        var note: String?
        var terminalOpen = true
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                note = "Stopped after \(Int(timeout)) s: commands that keep running (tail -f, top without -n) never end."
                break
            }
            var pollers = [pollfd(fd: outputEnd, events: Int16(POLLIN), revents: 0),
                           pollfd(fd: terminalOpen ? master : -1, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&pollers, 2, Int32(min(remaining, 1) * 1000))
            if ready < 0, errno == EINTR { continue }
            if ready < 0 { break }
            if ready == 0 { continue }
            if pollers[1].revents != 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    terminal += String(decoding: buffer[0..<count], as: UTF8.self)
                    switch Prompt(terminal) {
                    case .password where !typed && password != nil:
                        guard let password, ServerBroker.writeAll(master, Data((password + "\n").utf8)) else { break reading }
                        typed = true
                        terminal = ""
                    case .password:
                        note = password == nil ? "The server asks for a password, and none is saved." : "The server asked for the password again."
                        break reading
                    case .code:
                        note = "The server asks for a one-time code, which only a person can type: use the Servers panel's terminal."
                        break reading
                    case .none:
                        break
                    }
                } else {
                    // EIO once ssh is gone; its output may still be draining.
                    terminalOpen = false
                }
            }
            if pollers[0].revents != 0 {
                let count = read(outputEnd, &buffer, buffer.count)
                // EOF: ssh and everything it started have closed their output.
                guard count > 0 else { break }
                output.append(buffer, count: count)
                if output.count > outputLimit {
                    note = "Output cut at 1 MB; narrow the command (head, grep, tail -n)."
                    break
                }
            }
        }
        // What was written just before a stop is still worth returning.
        if note != nil {
            var drain = pollfd(fd: outputEnd, events: Int16(POLLIN), revents: 0)
            while output.count <= outputLimit, poll(&drain, 1, 0) > 0, (drain.revents & Int16(POLLIN)) != 0 {
                let count = read(outputEnd, &buffer, buffer.count)
                guard count > 0 else { break }
                output.append(buffer, count: count)
            }
        }
        close(outputEnd)
        close(master)
        var status: Int32 = 0
        var reaped = false
        if note != nil {
            // ssh leads its own process group (forkpty starts a session): stop all of it.
            kill(-pid, SIGTERM)
            let patience = Date().addingTimeInterval(2)
            while !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true } else if result < 0, errno != EINTR { break }
                guard Date() < patience else {
                    kill(-pid, SIGKILL)
                    break
                }
                if !reaped { usleep(50_000) }
            }
        }
        if !reaped { while waitpid(pid, &status, 0) < 0, errno == EINTR {} }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let text = String(decoding: output, as: UTF8.self)
        return ServerBroker.Reply(output: text, error: note, status: note == nil ? code : max(code, 1))
    }

    /// What ssh is waiting for at the end of what it printed so far.
    enum Prompt {
        case password, code, none

        init(_ text: String) {
            let tail = text.suffix(200).lowercased().trimmingCharacters(in: .whitespaces)
            if ["verification code:", "passcode:", "one-time password:", "otp:", "token code:"].contains(where: tail.hasSuffix) {
                self = .code
            } else if tail.hasSuffix("password:") {
                self = .password
            } else {
                self = .none
            }
        }
    }

}
