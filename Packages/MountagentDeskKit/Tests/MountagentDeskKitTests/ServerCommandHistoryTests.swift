import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ServerCommandHistoryTests {
    @Test func keepsPinnedOnTopAndNewestNext() {
        var history = ServerCommandHistory()
        let start = Date(timeIntervalSince1970: 1000)
        history.record("ls", at: start)
        history.record("sudo systemctl restart odoo-server", at: start.addingTimeInterval(1))
        history.record("git pull", at: start.addingTimeInterval(2))
        history.togglePin("ls")
        #expect(history.ordered.map(\.command) == ["ls", "git pull", "sudo systemctl restart odoo-server"])
        // Running a command again moves it up, without a duplicate.
        history.record("sudo systemctl restart odoo-server", at: start.addingTimeInterval(3))
        #expect(history.ordered.map(\.command) == ["ls", "sudo systemctl restart odoo-server", "git pull"])
        history.remove("git pull")
        #expect(history.entries.count == 2)
    }

    @Test func importedCommandsGoBelowKnownOnes() {
        var history = ServerCommandHistory()
        history.record("ls", at: Date(timeIntervalSince1970: 5000))
        history.merge(imported: ["cd /odoo", "ls", "sudo su - odoo"])
        #expect(history.ordered.map(\.command) == ["ls", "sudo su - odoo", "cd /odoo"])
    }

    @Test func capsUnpinnedCommands() {
        var history = ServerCommandHistory()
        history.record("keep me")
        history.togglePin("keep me")
        for index in 0..<520 { history.record("cmd \(index)", at: Date(timeIntervalSince1970: Double(index))) }
        #expect(history.entries.count == 501)
        #expect(history.entries.contains { $0.command == "keep me" })
        #expect(!history.entries.contains { $0.command == "cmd 0" })
    }

    @Test func readsTheCommandOffTheScreen() {
        let screen = "Welcome to Ubuntu\nubuntu@ip-172-31-31-243:~$ sudo systemctl restart odoo-server\n\n\n"
        #expect(ServerCommandHistory.commandLine(fromScreen: screen, columns: 80) == "sudo systemctl restart odoo-server")
        #expect(ServerCommandHistory.commandLine(fromScreen: "root@srv:/odoo# git pull", columns: 80) == "git pull")
        #expect(ServerCommandHistory.commandLine(fromScreen: "me@mac project % ls -la", columns: 80) == "ls -la")
        // A long command wraps onto the next row.
        let wrapped = "ubuntu@h:~$ sudo -u odoo -c \"cd /o\ndoo && git pull\""
        #expect(ServerCommandHistory.commandLine(fromScreen: wrapped, columns: 32) == "sudo -u odoo -c \"cd /odoo && git pull\"")
        #expect(ServerCommandHistory.commandLine(fromScreen: "[sudo] password for ubuntu: ", columns: 80) == nil)
        #expect(ServerCommandHistory.commandLine(fromScreen: "ubuntu@h:~$ ", columns: 80) == nil)
        #expect(ServerCommandHistory.commandLine(fromScreen: "some output without a prompt", columns: 80) == nil)
    }

    @Test func readsShellHistoryFiles() {
        let text = """
        #1700000000
        ls
        cd /odoo
        : 1700000001:0;git pull
        ls

        sudo su - odoo
        """
        #expect(ServerCommandHistory.parseShellHistory(text) == ["cd /odoo", "git pull", "ls", "sudo su - odoo"])
    }

    @Test func leavesSecretsOut() {
        for command in [
            "export API_KEY=abc123", "DB_PASSWORD=x ./run.sh", "mysql -u root -pS3cret db", "psql --password",
            "curl -H 'Authorization: Bearer xyz' https://api", "git clone https://me:tok@github.com/a/b",
            "curl -u admin:pw https://x", "sshpass -p pw ssh host", "odoo-bin --db_password=x", "mysql -pX db",
        ] {
            #expect(ServerCommandHistory.looksSecret(command), "\(command)")
        }
        for command in ["git log --author=alex", "tail -n 200 /var/log/odoo/odoo-server.log", "export PATH=$PATH:/opt/bin", "grep -i password /etc/odoo.conf | wc -l", "ls -la"] {
            #expect(!ServerCommandHistory.looksSecret(command), "\(command)")
        }
        #expect(ServerCommandHistory.parseShellHistory("ls\nexport TOKEN=x\ndf -h") == ["ls", "df -h"])
    }
}
