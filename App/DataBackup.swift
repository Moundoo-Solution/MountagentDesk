import AppKit
import MountagentDeskKit

/// Backs the data folder and settings up into one zip, and puts a backup back. Passwords
/// and tokens stay in this Mac's keychain and aren't in the zip.
@MainActor
enum DataBackup {
    static let settingsFile = "settings.plist"
    /// Not worth keeping: rebuilt at launch.
    static let skipped: Set<String> = ["helper.sock", "bin"]

    static func backUp(_ model: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Mountagent Desk backup \(Date().formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.finishWrites()
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("Mountagent Desk backup \(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent("Mountagent Desk", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(at: model.dataRoot, includingPropertiesForKeys: nil) where !skipped.contains(item.lastPathComponent) {
                try fileManager.copyItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent))
            }
            if let bundleID = Bundle.main.bundleIdentifier, let settings = UserDefaults.standard.persistentDomain(forName: bundleID) {
                let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
                try data.write(to: folder.appendingPathComponent(settingsFile))
            }
            try? fileManager.removeItem(at: destination)
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path])
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            model.alert = "Couldn't back up: \(error.localizedDescription)"
        }
    }

    static func restore(_ model: AppModel) {
        guard model.running.isEmpty else {
            model.alert = "Stop the agents that are working before restoring a backup."
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a Mountagent Desk backup"
        guard panel.runModal() == .OK, let archive = panel.url else { return }
        let fileManager = FileManager.default
        let unpacked = fileManager.temporaryDirectory.appendingPathComponent("Mountagent Desk restore \(UUID().uuidString)", isDirectory: true)
        do {
            // A zip from elsewhere could name paths outside the folder it unpacks to.
            let entries = try output("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n").map(String.init)
            guard !entries.contains(where: { $0.hasPrefix("/") || $0 == ".." || $0.hasPrefix("../") || $0.contains("/../") }) else {
                model.alert = "\(archive.lastPathComponent) has paths that lead outside it; it wasn't restored."
                return
            }
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            // Links have no place in the data folder.
            if let walker = fileManager.enumerator(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    try? fileManager.removeItem(at: item)
                }
            }
            let folder = unpacked.appendingPathComponent("Mountagent Desk", isDirectory: true)
            guard fileManager.fileExists(atPath: folder.appendingPathComponent("projects.json").path) else {
                model.alert = "\(archive.lastPathComponent) isn't a Mountagent Desk backup."
                return
            }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            let current = model.dataRoot
            let kept = current.deletingLastPathComponent().appendingPathComponent("\(current.lastPathComponent) before restore \(stamp)", isDirectory: true)
            let question = NSAlert()
            question.messageText = "Restore \(archive.lastPathComponent)?"
            question.informativeText = "Projects, sessions and settings are replaced by the backup's, and Mountagent Desk opens again. Today's data is kept in \u{201C}\(kept.lastPathComponent)\u{201D} next to it, so this can be undone."
            question.addButton(withTitle: "Restore")
            question.addButton(withTitle: "Cancel")
            guard question.runModal() == .alertFirstButtonReturn else { return }

            model.finishWrites()
            model.stopHelperListener()
            try fileManager.moveItem(at: current, to: kept)
            let settings = folder.appendingPathComponent(settingsFile)
            if let data = try? Data(contentsOf: settings),
               var values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let bundleID = Bundle.main.bundleIdentifier {
                // Settings that name programs to run (an agent CLI's path) stay as they are here.
                for key in values.keys where key.hasSuffix("Path") { values[key] = nil }
                let current = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
                for (key, value) in current where key.hasSuffix("Path") { values[key] = value }
                UserDefaults.standard.setPersistentDomain(values, forName: bundleID)
            }
            try? fileManager.removeItem(at: settings)
            try fileManager.moveItem(at: folder, to: current)
            relaunch()
        } catch {
            model.alert = "Couldn't restore: \(error.localizedDescription)"
        }
        try? fileManager.removeItem(at: unpacked)
    }

    /// Opens a fresh copy of the app, which waits for this one to quit.
    private static func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \(Shell.quote(bundle))"]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func output(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DataBackup", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "The backup couldn't be read."])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "DataBackup", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "\(tool) failed." : message])
        }
    }
}
