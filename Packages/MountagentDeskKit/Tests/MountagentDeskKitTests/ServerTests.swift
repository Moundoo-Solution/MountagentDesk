import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ServerCommandPolicyTests {
    /// As on a server where agents may sudo to these users.
    private func allows(_ command: String) -> Bool {
        if case .allowed = ServerCommandPolicy.check(command, sudoUsers: ["postgres", "odoo", "root"]) { return true }
        return false
    }

    @Test func allowsReading() {
        for command in [
            "tail -n 200 /var/log/odoo/odoo-server.log",
            "grep -n -E 'ERROR|Traceback' /var/log/odoo/odoo-server.log | tail -n 50",
            "ls -la /opt/odoo && df -h",
            "ps aux --sort=-%mem | head -n 15",
            "journalctl -u odoo -n 100 --no-pager",
            "systemctl status odoo --no-pager",
            "sudo -u odoo cat /etc/odoo/odoo.conf",
            "cat /var/log/syslog 2>/dev/null | grep -c error",
            "find /opt/odoo -name '*.py' -newer /tmp/x",
            "git -C /opt/odoo/custom log --oneline -5",
            "docker logs --tail 100 odoo",
            "top -b -n 1",
            "crontab -l -u odoo",
            "echo \"a > b; c\"",
        ] {
            #expect(allows(command), "\(command)")
        }
    }

    @Test func keepsServiceSecretsIn() {
        for command in ["docker inspect web", "docker inspect -f '{{.Config.Env}}' web", "docker inspect --format '{{json .}}' web",
                        "docker inspect --format '{{.State.Status}} {{.Config.Env}}' web", "systemctl show odoo", "systemctl cat odoo", "ps auxe", "ps eww 1"] {
            #expect(!allows(command), "\(command)")
        }
        for command in ["docker inspect --format '{{.State.Status}}' web", "docker inspect -f '{{ .RestartCount }} {{.State.StartedAt}}' web", "ps aux", "ps -ef", "systemctl status nginx --no-pager"] {
            #expect(allows(command), "\(command)")
        }
    }

    @Test func sudoOnlyToTheUsersAllowed() {
        func verdict(_ command: String, _ users: [String]) -> Bool {
            if case .allowed = ServerCommandPolicy.check(command, sudoUsers: users) { return true }
            return false
        }
        #expect(!verdict("sudo cat /etc/shadow", []))
        #expect(!verdict("sudo -u postgres psql -l", []))
        #expect(verdict("sudo -u postgres psql -l", ["postgres"]))
        #expect(!verdict("sudo cat /etc/shadow", ["postgres"]), "plain sudo is root")
        #expect(!verdict("sudo -u www-data cat x", ["postgres"]))
        #expect(verdict("sudo cat /var/log/syslog", ["root"]))
        #expect(verdict("tail -n 5 /var/log/syslog", []))
    }

    @Test func refusesWaysAroundTheChecks() {
        for command in [
            // psql: combined flags, abbreviations, files, variables and pagers.
            "psql -c 'select 1' -qc '\\! curl x|sh'",
            "psql -Xc 'select 1' -qf /tmp/x.sql",
            "psql -qo /tmp/out -c 'select 1'",
            "psql --comm='select 1'",
            "psql -v x=1 -c 'select 1'",
            "psql -P pager=on -c 'select 1'",
            "psql -1 -c 'select 1'",
            "sudo -u postgres psql -d db -qAtc 'select \"pg_terminate_backend\"(pid) from pg_stat_activity'",
            "psql -c \"select query_to_xml('select pg_terminate_backend(1)', true, true, '')\"",
            "psql -c 'select pg_catalog.\"pg_cancel_backend\"(1)'",
            // GNU long options in shortened forms.
            "echo key | sort --out=/home/u/.ssh/authorized_keys",
            "sort --compress-program=sh x",
            "tail --fol=name /var/log/syslog",
            "journalctl --rot",
            "date --se='2020-01-01'",
            "git log --outp=/tmp/x",
            "file -C -m /tmp/magic",
            "sudo ss -K dst 10.0.0.1",
        ] {
            #expect(!allows(command), "\(command)")
        }
        for command in [
            "psql -d odoo -U odoo -qAt -c 'select count(*) from res_partner'",
            "sudo -u postgres psql -qAtc 'select 1'",
            "psql --dbname=odoo --tuples-only --command='select 1'",
            "psql -l",
            "sort -k2 -n x | uniq -c",
            "tail -n 100 /var/log/syslog",
            "journalctl -u odoo --since today --no-pager",
            "ss -tunlp",
            "file /etc/hosts",
            "date +%F",
            "git log --oneline -5",
        ] {
            #expect(allows(command), "\(command)")
        }
    }

    @Test func refusesChanges() {
        for command in [
            "rm -rf /tmp/x",
            "sudo systemctl restart odoo",
            "cat a > b",
            "echo hi >> /etc/hosts",
            "tail -f /var/log/odoo.log",
            "tail -fn 10 x",
            "ls; rm x",
            "ls && sudo rm x",
            "cat $(which odoo)",
            "cat `which odoo`",
            "echo \"$(reboot)\"",
            "ls &",
            "(rm x)",
            "find / -name x -delete",
            "find . -exec rm {} \\;",
            "sort -o out in",
            "/bin/rm x",
            "PATH=/tmp ls",
            "sudo -s",
            "sed -i s/a/b/ f",
            "awk '{system(\"rm x\")}' f",
            "git push",
            "git branch -D main",
            "docker rm odoo",
            "date -s 2020-01-01",
            "cat < /etc/passwd",
            "ls 'unclosed",
            "ls |",
            "crontab -r",
        ] {
            #expect(!allows(command), "\(command)")
        }
    }

    @Test func makesPsqlReadOnly() {
        let verdict = ServerCommandPolicy.check("sudo -u postgres psql -d prod -c \"SELECT id, name FROM res_partner WHERE name ILIKE '%update%'\"", sudoUsers: ["postgres"])
        #expect(verdict == .allowed("sudo -u postgres psql -X -c 'SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY' -d prod -c \"SELECT id, name FROM res_partner WHERE name ILIKE '%update%'\""))
        #expect(allows("psql -l"))
        #expect(allows("psql -d prod -c 'EXPLAIN SELECT 1'"))
        #expect(allows("psql -d prod -c \"SELECT comment, start_date FROM x\""))
    }

    @Test func refusesWritingSQL() {
        for query in [
            "UPDATE res_partner SET name = 'x'",
            "SELECT 1; DELETE FROM res_partner",
            "WITH d AS (DELETE FROM x RETURNING *) SELECT * FROM d",
            "SELECT * INTO backup FROM res_partner",
            "SELECT pg_terminate_backend(123)",
            "EXPLAIN ANALYZE DELETE FROM x",
            "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
            "\\! rm -rf /",
            "SELECT * FROM x FOR UPDATE",
            "SELECT nextval('seq')",
        ] {
            #expect(ServerCommandPolicy.sqlRefusal(query) != nil, "\(query)")
        }
        #expect(!allows("psql -d prod"))
        #expect(!allows("psql -f script.sql"))
    }
}

@Suite struct ServerTests {
    @Test func readsSSHConfigHosts() {
        let entries = SSHConfigImport.parse("""
        Host *
          ServerAliveInterval 30
        Host acme-live live2
          HostName 10.0.0.5
          User odoo
          Port 2222
          IdentityFile ~/.ssh/id_acme
        Host acme-uat
          HostName uat.acme.com
        Match host foo
          User nobody
        """)
        #expect(entries.map(\.alias) == ["acme-live", "live2", "acme-uat"])
        #expect(entries[0].hostName == "10.0.0.5")
        #expect(entries[0].user == "odoo")
        #expect(entries[0].port == 2222)
        #expect(entries[0].identityFile?.hasSuffix("/.ssh/id_acme") == true)
        #expect(entries[0].summary == "odoo@10.0.0.5:2222")
        #expect(entries[0].server.environment == .live)
        #expect(entries[2].server.environment == .uat)
        #expect(entries[2].user == nil)
    }

    @Test func buildsSSHArguments() {
        let key = ServerCredential(name: "acme", user: "ubuntu", keyPath: "/k/id")
        let server = Server(name: "Acme Live", host: "10.0.0.5", port: 2222, credentialID: key.id)
        let login = server.login(with: [key])
        #expect(server.environment == .live)
        #expect(login.destination == "ubuntu@10.0.0.5")
        #expect(server.handle == "acme-live")
        #expect(login.commandArguments("df -h").suffix(8) == ["-p", "2222", "-i", "/k/id", "-o", "IdentitiesOnly=yes", "ubuntu@10.0.0.5", "df -h"])
        #expect(!server.aiReadAccess)
        // The server's own user wins; without a credential the SSH config decides.
        var own = server
        own.user = "odoo"
        #expect(own.login(with: [key]).destination == "odoo@10.0.0.5")
        #expect(Server(name: "x", host: "h").login(with: []).destination == "h")
        #expect(key.summary == "ubuntu · key")
    }

    @Test func passwordCredentialsUseAskpass() {
        var credential = ServerCredential(name: "uat", user: "ubuntu")
        let server = Server(name: "Acme UAT", host: "h", credentialID: credential.id)
        let askpass = URL(fileURLWithPath: "/x/mountagent-server")
        #expect(server.login(with: [credential]).commandArguments("ls").contains("BatchMode=yes"))
        #expect(server.login(with: [credential]).askpassEnvironment(askpass: askpass).isEmpty)
        credential.hasPassword = true
        let login = server.login(with: [credential])
        #expect(!login.commandArguments("ls").contains("BatchMode=yes"))
        #expect(login.askpassEnvironment(askpass: askpass) == [
            "SSH_ASKPASS": "/x/mountagent-server", "SSH_ASKPASS_REQUIRE": "force",
            "MOUNTAGENT_ASKPASS_ACCOUNT": credential.id.uuidString,
        ])
        // The server's own password wins over the credential's.
        var own = server
        own.passwordSaved = true
        #expect(own.login(with: [credential]).askpassEnvironment(askpass: askpass)["MOUNTAGENT_ASKPASS_ACCOUNT"] == "server-" + server.id.uuidString)
        #expect(!Server(name: "a", host: "h", passwordSaved: true).login(with: []).commandArguments("ls").contains("BatchMode=yes"))
    }

    @Test func movesOldServerLoginsIntoCredentials() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","name":"Acme Live","host":"h","user":"odoo","keyPath":"/k/id","environment":"live","environmentName":"Prod","aiReadAccess":true,"hasPassword":true}]"#
        var servers = try JSONDecoder().decode([Server].self, from: Data(json.utf8))
        #expect(servers[0].aiReadAccess && servers[0].credentialID == nil)
        let credentials = ServerCredential.migrate(Data(json.utf8), servers: &servers)
        #expect(credentials == [ServerCredential(id: id, name: "Acme Live", user: "odoo", keyPath: "/k/id", hasPassword: true)])
        #expect(servers[0].credentialID == id)
        // Already moved: nothing more to do.
        let again = try JSONEncoder().encode(servers)
        #expect(ServerCredential.migrate(again, servers: &servers).isEmpty)
    }

    @Test func askpassOnlyAnswersTheAppsSSH() {
        // The test runner isn't ssh started by the app, so nothing is revealed.
        #expect(!ServerPasswords.calledByAppSSH())
        #expect(ServerPasswords.answerAskpass(account: UUID().uuidString, prompt: "odoo@h's password:") == 1)
        #expect(ServerPasswords.answerAskpass(account: UUID().uuidString, prompt: "Enter passphrase for key") == 1)
    }

    @Test func importsKeyFilesPrivately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskKeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("acme.pem")
        try "KEY".write(to: source, atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("store")
        let path = try ServerKeys.importKey(from: source, into: target)
        #expect(path == target.appendingPathComponent("acme.pem").path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The same file again is reused; a different one with that name gets a new name.
        #expect(try ServerKeys.importKey(from: source, into: target) == path)
        try "OTHER".write(to: source, atomically: true, encoding: .utf8)
        #expect(try ServerKeys.importKey(from: source, into: target) == target.appendingPathComponent("acme-2.pem").path)
    }

    @Test func oldProjectsHaveNoServers() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"p","path":"/tmp","createdAt":0,"defaultAgent":"claude"}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.serverIDs.isEmpty)
    }

    @Test func listsOnlyReadableLinkedServers() {
        let open = Server(name: "uat", host: "u", aiReadAccess: true)
        let closed = Server(name: "live", host: "l")
        let elsewhere = Server(name: "other", host: "o", aiReadAccess: true)
        var project = Project(name: "p", path: "/tmp")
        project.serverIDs = [open.id, closed.id]
        #expect(ServerHelper.readable(in: project, servers: [open, closed, elsewhere]) == [open])
    }

    @Test func writesTheWrapper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskHelper-\(UUID().uuidString)")
        let bin = try ServerHelper.installWrapper(executable: "/Applications/Mountagent Desk.app/Contents/MacOS/Mountagent Desk", in: root)
        let script = try String(contentsOf: bin.appendingPathComponent("mountagent-server"), encoding: .utf8)
        #expect(script == "#!/bin/sh\nexec '/Applications/Mountagent Desk.app/Contents/MacOS/Mountagent Desk' --server-exec \"$@\"\n")
        #expect(FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("mountagent-server").path))
    }

    @Test func claudeKeepsAgentsOffServers() {
        var request = AgentRunRequest(prompt: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), model: nil, access: .fullAccess, resumeSessionID: nil)
        #expect(!ClaudeProvider().invocation(for: request).arguments.contains("--disallowedTools"))
        request.linksServers = true
        request.readsServers = true
        let arguments = ClaudeProvider().invocation(for: request).arguments
        let denied = try? #require(arguments.firstIndex(of: "--disallowedTools").map { arguments[$0 + 1] })
        for rule in ["Bash(ssh:*)", "Bash(/usr/bin/ssh:*)", "Bash(env ssh:*)", "Bash(command scp:*)", "Bash(rsync:*)"] {
            #expect(denied?.contains(rule) == true, "\(rule)")
        }
        #expect(arguments.contains("Bash(mountagent-server:*)"))
    }
}

@Suite struct ServerBrokerTests {
    private let project: Project = {
        var project = Project(name: "Acme", path: "/tmp")
        project.serverIDs = []
        return project
    }()

    private func servers(linkedTo project: inout Project) -> (open: Server, closed: Server, other: Server) {
        let open = Server(name: "Acme UAT", host: "uat.example.com", aiReadAccess: true)
        let closed = Server(name: "Acme Live", host: "live.example.com", aiReadAccess: false)
        let other = Server(name: "Other", host: "other.example.com", aiReadAccess: true)
        project.serverIDs = [open.id, closed.id]
        return (open, closed, other)
    }

    @Test func decidesFromTheRunsProjectOnly() {
        var project = project
        let (open, closed, other) = servers(linkedTo: &project)
        let all = [open, closed, other]
        func decide(_ server: String?, _ command: String, in project: Project?) -> ServerHelper.Decision {
            ServerHelper.decide(ServerBroker.Request(token: "t", server: server, command: command), project: project, servers: all)
        }
        guard case .reply(let unknown) = decide("acme-uat", "ls", in: nil) else { Issue.record("an unknown token ran"); return }
        #expect(unknown.status != 0)
        guard case .reply(let notLinked) = decide("other", "ls", in: project) else { Issue.record("an unlinked server ran"); return }
        #expect(notLinked.error?.contains("No server named other") == true)
        guard case .reply(let off) = decide("acme-live", "ls", in: project) else { Issue.record("a server without access ran"); return }
        #expect(off.error?.contains("Agent access") == true)
        guard case .reply(let blocked) = decide("acme-uat", "rm -rf /", in: project) else { Issue.record("a write ran"); return }
        #expect(blocked.error?.contains("read-only") == true)
        #expect(decide("acme-uat", "tail -n 5 /var/log/syslog", in: project) == .run(open, command: "tail -n 5 /var/log/syslog"))
        guard case .reply(let list) = decide(nil, "", in: project) else { Issue.record("list didn't reply"); return }
        #expect(list.output.contains("acme-uat\tAcme UAT\treadable") && list.output.contains("agent access off") && !list.output.contains("Other"))
    }

    @Test func agentSSHIgnoresTheUsersConfig() {
        let credential = ServerCredential(name: "k", user: "deploy", keyPath: "/keys/acme.pem")
        let server = Server(name: "Acme UAT", host: "acme-uat", credentialID: credential.id)
        var entry = SSHConfigImport.Entry(alias: "acme-uat")
        entry.hostName = "10.0.0.5"
        entry.port = 2222
        let arguments = SSHLogin(server: server, credential: credential).agentArguments("ls", config: entry)
        #expect(Array(arguments.prefix(2)) == ["-F", "/dev/null"])
        #expect(arguments.contains("StrictHostKeyChecking=yes") && arguments.contains("BatchMode=yes") && arguments.contains("-n"))
        #expect(arguments.suffix(2) == ["deploy@10.0.0.5", "ls"])
        #expect(arguments.contains("2222") && arguments.contains("/keys/acme.pem"))
    }

    @Test func helperAndAppTalkOverTheSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/mad-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let listener = ServerBroker.Listener(root: root) { request in
            ServerBroker.Reply(output: "\(request.server ?? "-") \(request.command)", error: request.token == "good" ? nil : "bad token", status: 7)
        }
        try listener.start()
        defer { listener.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: ServerBroker.socketURL(in: root).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let reply = try ServerBroker.send(ServerBroker.Request(token: "good", server: "acme-uat", command: "df -h"), root: root)
        #expect(reply == ServerBroker.Reply(output: "acme-uat df -h", status: 7))
        #expect(try ServerBroker.send(ServerBroker.Request(token: "x", server: nil, command: ""), root: root).error == "bad token")
    }

    @Test func aQuittingCopyLeavesTheNewSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/mad-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = ServerBroker.Listener(root: root) { _ in ServerBroker.Reply(output: "old", status: 0) }
        try old.start()
        let new = ServerBroker.Listener(root: root) { _ in ServerBroker.Reply(output: "new", status: 0) }
        try new.start()
        old.stop()
        defer { new.stop() }
        #expect(try ServerBroker.send(ServerBroker.Request(token: "t", server: nil, command: ""), root: root).output == "new")
    }

    /// A stand-in for ssh that asks on its terminal, as ssh does.
    private func fakeSSH(_ body: String) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ssh-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }

    @Test func typesTheSavedPasswordAtSSHsPrompt() throws {
        let ssh = try fakeSSH(#"stty -echo </dev/tty; printf "me@host's password: " >/dev/tty; read p </dev/tty; stty echo </dev/tty; echo >/dev/tty; echo "got:$p"; exit 3"#)
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let reply = ServerRun.ssh([], password: "s3cret", executable: ssh, timeout: 10)
        #expect(reply.output == "got:s3cret\n", "\(reply)")
        #expect(reply.status == 3 && reply.error == nil)
    }

    @Test func neverTypesThePasswordIntoTheServersOutput() throws {
        // Signed in by key: no prompt from ssh, but the command prints something like one.
        let ssh = try fakeSSH(#"printf "Enter the admin password: "; read -t 2 x </dev/tty; echo; echo "typed:$x""#)
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let reply = ServerRun.ssh([], password: "s3cret", executable: ssh, timeout: 10)
        #expect(!reply.output.contains("s3cret"))
        #expect(reply.output.contains("typed:\n"), "\(reply)")
    }

    @Test func stopsAtAOneTimeCode() throws {
        let ssh = try fakeSSH(#"printf "Password: " >/dev/tty; read p </dev/tty; printf "Verification code: " >/dev/tty; read c </dev/tty; echo "in"; exit 0"#)
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let reply = ServerRun.ssh([], password: "pw", executable: ssh, timeout: 10)
        #expect(reply.error?.contains("one-time code") == true)
        #expect(reply.status != 0 && !reply.output.contains("in"))
    }

    @Test func stopsCommandsThatNeverEnd() throws {
        let ssh = try fakeSSH("echo start; sleep 30")
        defer { try? FileManager.default.removeItem(atPath: ssh) }
        let started = Date()
        let reply = ServerRun.ssh([], password: nil, executable: ssh, timeout: 1)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(reply.output == "start\n" && reply.error?.contains("Stopped after") == true, "\(reply)")
    }

    @Test func recognisesPrompts() {
        #expect(ServerRun.Prompt("(me@host) Password: ") == .password)
        #expect(ServerRun.Prompt("me@10.0.0.1's password:") == .password)
        #expect(ServerRun.Prompt("One-time password: ") == .code)
        #expect(ServerRun.Prompt("Verification code: ") == .code)
        #expect(ServerRun.Prompt("total 4\nfile\n") == .none)
    }
}
