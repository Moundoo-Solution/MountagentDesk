import Foundation

/// Keeps the app's own git commands from running programs that a repository names in its
/// own config. Agents can edit `.git/config` and `.gitattributes`, and the app runs git in
/// their repositories by itself (a checkpoint before every turn, the Git window's status
/// every few seconds), so a planted fsmonitor, clean/smudge filter, textconv or external
/// diff would otherwise run as the user, outside the agent's access level.
///
/// Filters set up in the user's own config (`git lfs install` writes them globally) are
/// trusted, and so is the standard LFS setup in a repository. Other filters in the
/// repository's config are emptied with `-c`, which wins over it; a long-running `process`
/// filter can't be emptied (git gives up), so git isn't run there at all until it's removed.
/// diff, log, show and blame also get `--no-ext-diff --no-textconv`.
enum GitSafety {
    struct Refusal: LocalizedError {
        let driver: String
        var errorDescription: String? {
            "This repository's git config sets filter.\(driver).process, a program git would run. Mountagent Desk doesn't run git here until it's removed: git config --unset filter.\(driver).process"
        }
    }

    static func arguments(_ arguments: [String], root: URL, runsHooks: Bool) throws -> [String] {
        var options = ["-c", "core.fsmonitor=false"]
        if !runsHooks { options += ["-c", "core.hooksPath=/dev/null"] }
        let drivers = repositoryFilters(in: root)
        if let process = drivers.first(where: \.hasProcess) { throw Refusal(driver: process.name) }
        for driver in drivers {
            options += ["-c", "filter.\(driver.name).clean=", "-c", "filter.\(driver.name).smudge=", "-c", "filter.\(driver.name).required=false"]
        }
        var command = arguments
        if let subcommand = command.first, ["diff", "log", "show", "blame"].contains(subcommand) {
            command.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1)
        }
        return options + command
    }

    struct Driver: Equatable {
        let name: String
        var hasProcess = false
    }

    /// The standard Git LFS setup, which `git lfs install --local` writes into a repository.
    static let lfsValues: Set<String> = ["git-lfs clean -- %f", "git-lfs smudge -- %f", "git-lfs filter-process", "true"]

    /// Filters defined in the repository's own config, read before every command (a cache
    /// would leave a moment in which a freshly planted filter runs).
    static func repositoryFilters(in root: URL) -> [Driver] {
        let process = Process()
        process.executableURL = ExecutableLocator.find("git") ?? URL(fileURLWithPath: "/usr/bin/git")
        // Reading config runs nothing.
        process.arguments = ["-C", root.path, "config", "--show-scope", "--get-regexp", #"^filter\."#]
        process.environment = ExecutableLocator.environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var drivers: [Driver] = []
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            drivers = parse(String(decoding: data, as: UTF8.self))
        }
        return drivers
    }

    /// `git config --show-scope --get-regexp` lines: `<scope>\t<key> <value>`.
    static func parse(_ text: String) -> [Driver] {
        var drivers: [Driver] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == "local" || parts[0] == "worktree" else { continue }
            let entry = parts[1].split(separator: " ", maxSplits: 1).map(String.init)
            let key = entry[0], value = entry.count > 1 ? entry[1] : ""
            guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), !lfsValues.contains(value) || !key.hasPrefix("filter.lfs.") else { continue }
            let name = String(key[key.index(key.startIndex, offsetBy: 7)..<dot])
            guard !name.isEmpty else { continue }
            let variable = key[key.index(after: dot)...]
            if let index = drivers.firstIndex(where: { $0.name == name }) {
                if variable == "process" { drivers[index].hasProcess = true }
            } else {
                drivers.append(Driver(name: name, hasProcess: variable == "process"))
            }
        }
        return drivers
    }
}
