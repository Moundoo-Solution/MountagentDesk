import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct MultiFolderTests {
    @Test func decodesProjectsSavedBeforeMultiFolder() throws {
        let json = #"[{"id":"6F2C1E59-6B39-4C47-9F57-0B1D2C3D4E5F","name":"shop-16","path":"/src/shop-16","createdAt":0,"defaultAgent":"claude"}]"#
        let projects = try JSONDecoder().decode([Project].self, from: Data(json.utf8))
        #expect(projects.first?.additionalPaths == [])
        #expect(projects.first?.loadsAdditionalRules == false)
    }

    @Test func managesFolders() {
        var project = Project(name: "shop", path: "/src/shop-16")
        #expect(project.addFolders(["/src/shop-19", "/src/shop-16", "/src/odoo-19", "/src/shop-19"]) == 2)
        #expect(project.allPaths == ["/src/shop-16", "/src/shop-19", "/src/odoo-19"])

        project.makePrimary("/src/odoo-19")
        #expect(project.path == "/src/odoo-19")
        #expect(project.additionalPaths == ["/src/shop-19", "/src/shop-16"])
    }

    @Test func displaysAndHandsOverPaths() {
        let project = Project(name: "shop", path: "/src/shop-16", additionalPaths: ["/src/odoo-19", "/src/odoo-19/addons"])
        #expect(project.displayPath("/src/shop-16/models/sale.py") == "models/sale.py")
        #expect(project.displayPath("/src/odoo-19/odoo/fields.py") == "odoo-19/odoo/fields.py")
        #expect(project.displayPath("/src/odoo-19/addons/sale/models/sale.py") == "addons/sale/models/sale.py")
        #expect(project.displayPath("grep -rn foo /src/shop-16/models /src/odoo-19/odoo") == "grep -rn foo models odoo-19/odoo")

        #expect(project.agentPath(for: URL(fileURLWithPath: "/src/shop-16/models/sale.py")) == "models/sale.py")
        #expect(project.agentPath(for: URL(fileURLWithPath: "/src/odoo-19/odoo/fields.py")) == "/src/odoo-19/odoo/fields.py")
    }

    private func request(resume: String?, rules: Bool, extra: [URL]) -> AgentRunRequest {
        AgentRunRequest(prompt: "hi", workingDirectory: URL(fileURLWithPath: "/src/main"), additionalDirectories: extra, loadsAdditionalRules: rules, model: nil, access: .editFiles, resumeSessionID: resume)
    }

    @Test func claudeGetsAddDirsAndRulesSwitch() {
        let extra = [URL(fileURLWithPath: "/src/a"), URL(fileURLWithPath: "/src/b")]
        let invocation = ClaudeProvider().invocation(for: request(resume: nil, rules: true, extra: extra))
        #expect(invocation.arguments.joined(separator: " ").contains("--add-dir /src/a --add-dir /src/b"))
        #expect(invocation.environment["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] == "1")
        #expect(ClaudeProvider().invocation(for: request(resume: nil, rules: false, extra: extra)).environment.isEmpty)
    }

    @Test func cursorGetsAddDirsAndRulesOnFirstTurnOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskExtra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Use the ORM, never raw SQL.".write(to: folder.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let first = CursorProvider().invocation(for: request(resume: nil, rules: true, extra: [folder])).arguments
        #expect(first.contains("--add-dir"))
        #expect(first.last?.contains("Use the ORM, never raw SQL.") == true)
        #expect(first.last?.hasSuffix("\n\nhi") == true)

        let resumed = CursorProvider().invocation(for: request(resume: "abc", rules: true, extra: [folder])).arguments
        #expect(resumed.last == "hi")
        let off = CursorProvider().invocation(for: request(resume: nil, rules: false, extra: [folder])).arguments
        #expect(off.last == "hi")
    }
}
