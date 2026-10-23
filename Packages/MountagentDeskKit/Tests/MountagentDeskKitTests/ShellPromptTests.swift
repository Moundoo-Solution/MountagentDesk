import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct ShellPromptTests {
    /// Starts an interactive login zsh the way the app's terminal does and prints `expression`.
    private func run(home: URL, _ expression: String) throws -> String {
        let root = home.appendingPathComponent("app")
        let zdotdir = try ShellPrompt.install(in: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", "print -r -- \(expression)"]
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        environment.merge(ShellPrompt.environment(zdotdir: zdotdir, current: environment)) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskZsh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func colorsThePlainPrompt() throws {
        let home = try home()
        try "export FROM_ZSHRC=yes\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "export FROM_ZSHENV=yes\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        let output = try run(home: home, "\"$PROMPT|$FROM_ZSHRC|$FROM_ZSHENV|$HISTFILE|$ZDOTDIR\"")
        let parts = output.components(separatedBy: "|")
        #expect(parts.count == 5)
        #expect(parts[0].contains("%F{green}%n@%m%f") && parts[0].contains("vcs_info_msg_0_"))
        #expect(parts[1] == "yes" && parts[2] == "yes")
        #expect(parts[3] == home.path + "/.zsh_history")
        #expect(parts[4] == home.path)
    }

    @Test func keepsTheUsersOwnPrompt() throws {
        let home = try home()
        try "PROMPT='mine> '\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        #expect(try run(home: home, "\"$PROMPT\"") == "mine> ")
    }
}
