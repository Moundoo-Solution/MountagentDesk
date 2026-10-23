import Foundation
import Testing
@testable import MountagentDeskKit

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ProjectStoreTests {
    @Test func movesLegacyDataAndLinksTheOldPath() throws {
        let base = try temporaryDirectory()
        let legacy = base.appendingPathComponent("AgentDesk", isDirectory: true)
        let root = base.appendingPathComponent("Mountagent Desk", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy.appendingPathComponent("projects.json"))

        ProjectStore.moveLegacyData(from: legacy, to: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects.json").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == root.path)
        // Once moved, it is left alone.
        ProjectStore.moveLegacyData(from: legacy, to: root)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["projects.json"])
    }

    @Test func roundTripsProjectsAndSessions() throws {
        let store = ProjectStore(root: try temporaryDirectory(), trashesDeleted: false)
        let project = Project(name: "Demo", path: "/tmp/demo")
        try store.saveProjects([project])
        #expect(try store.loadProjects() == [project])

        var older = ChatSession(projectID: project.id, agent: .claude)
        older.updatedAt = .now.addingTimeInterval(-60)
        older.agentSessionIDs[.claude] = "abc"
        older.models[.cursor] = "gpt-5.2"
        let newer = ChatSession(projectID: project.id, agent: .cursor)
        try store.save(older)
        try store.save(newer)

        let loaded = store.loadSessions(of: project.id)
        #expect(loaded.map(\.id) == [newer.id, older.id])
        #expect(loaded.last?.agentSessionIDs[.claude] == "abc")
        #expect(loaded.last?.models[.cursor] == "gpt-5.2")

        try store.delete(newer)
        #expect(store.loadSessions(of: project.id).count == 1)
    }

    @Test func setsDamagedFilesAside() throws {
        let root = try temporaryDirectory()
        let store = ProjectStore(root: root, trashesDeleted: false)
        let project = Project(name: "p", path: "/tmp")
        var session = ChatSession(projectID: project.id, agent: .claude)
        session.items = [ChatItem(kind: .user, text: "hi"), ChatItem(kind: .notice, text: "kept")]
        try store.save(session)
        let folder = root.appendingPathComponent("sessions/\(project.id.uuidString)")

        // A row of a kind this version doesn't know drops alone.
        let file = folder.appendingPathComponent("\(session.id.uuidString).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var items = json["items"] as! [[String: Any]]
        items[0]["kind"] = "fromTheFuture"
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(store.loadSessions(of: project.id).first?.items.map(\.text) == ["kept"])

        // A file that doesn't decode at all is moved aside and reported.
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("\(UUID().uuidString).json"))
        let result = store.loadSessionsSettingAsideDamage(of: project.id)
        #expect(result.sessions.count == 1 && result.setAside.count == 1)
        #expect(result.setAside.first?.pathExtension.hasPrefix("corrupt-") == true)
        #expect(store.loadSessionsSettingAsideDamage(of: project.id).setAside.isEmpty)
    }
}

@Suite struct ProjectContextTests {
    @Test func linksAgentsFileAndManagesSkills() throws {
        let context = ProjectContext(root: try temporaryDirectory())
        #expect(!context.claudeReadsAgentsFile)

        try context.write("Keep it short.\n", to: "CLAUDE.md")
        try context.linkAgentsFileToClaude()
        #expect(context.claudeReadsAgentsFile)
        #expect(context.read("CLAUDE.md") == "@AGENTS.md\n\nKeep it short.\n")

        let skill = try context.createSkill(name: "Odoo Upgrade", description: "Upgrade a module")
        #expect(skill.relativePath == ".claude/skills/odoo-upgrade/SKILL.md")
        #expect(context.skills().map(\.description) == ["Upgrade a module"])

        let rule = context.newRulePath(named: "Python style", for: .cursor)
        try context.write(context.template(for: rule), to: rule)
        #expect(context.files().contains { $0.relativePath == ".cursor/rules/python-style.mdc" && $0.group == .cursor })

        try context.deleteSkill(skill)
        #expect(context.skills().isEmpty)
    }

    @Test func slugsNames() {
        #expect(ProjectContext.slug("Sửa lỗi Đơn hàng!") == "sua-loi-don-hang")
    }
}

@Suite struct SavedAgentTests {
    /// Gemini CLI was an agent in earlier versions; its sessions and projects must still load.
    @Test func readsAgentsEarlierVersionsSaved() throws {
        let json = #"{"id":"6F2C1E59-6B39-4C47-9F57-0B1D2C3D4E5F","projectID":"7F2C1E59-6B39-4C47-9F57-0B1D2C3D4E5F","title":"t","agent":"gemini","models":{"gemini":"pro","claude":"opus","someday":"x"},"agentSessionIDs":{"gemini":"g1"},"createdAt":0}"#
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.agent == .antigravity)
        #expect(session.models == [.antigravity: "pro", .claude: "opus"], "an unknown agent's entry is dropped, not fatal")
        #expect(session.agentSessionIDs[.antigravity] == "g1")
        #expect(AgentKind(stored: "someday") == nil)
    }
}
