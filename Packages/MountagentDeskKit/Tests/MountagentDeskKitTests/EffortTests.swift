import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct EffortTests {
    private func families() throws -> [ModelFamily] {
        let url = try #require(Bundle.module.url(forResource: "cursor-models", withExtension: "txt", subdirectory: "Fixtures"))
        let output = try String(contentsOf: url, encoding: .utf8)
        return ModelCatalog.cursorFamilies(from: CursorProvider.parseModels(output))
    }

    @Test func foldsCursorVariantsIntoFamilies() throws {
        let families = try families()
        #expect(families.first?.id == "auto")

        let opus = try #require(families.first { $0.id == "claude-opus-5-5" })
        #expect(opus.name == "Claude Opus 5.5 1M")
        #expect(opus.efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(opus.defaultEffort == "medium")
        #expect(opus.hasFast)
        #expect(opus.modelID(effort: "xhigh", fast: true) == "claude-opus-5-5-xhigh-fast")
        #expect(opus.modelID(effort: nil, fast: false) == "claude-opus-5-5-medium")

        let grok = try #require(families.first { $0.id == "cursor-grok-4.6" })
        #expect(grok.name == "Grok 4.6")
        #expect(grok.defaultEffort == "high")

        let composer = try #require(families.first { $0.id == "composer-2.5" })
        #expect(!composer.hasEffort)
        #expect(composer.hasFast)

        // No family is listed twice, and every model id is reachable.
        #expect(Set(families.map(\.id)).count == families.count)
        let ids = families.flatMap { $0.variants.compactMap(\.modelID) }
        #expect(ids.count == Set(ids).count)
    }

    @Test func fallsBackToTheNearestVariant() {
        let family = ModelCatalog.cursorFamilies(from: [
            AgentModel(id: "gpt-5.3-codex", name: "Codex 5.3"),
            AgentModel(id: "gpt-5.3-codex-high", name: "Codex 5.3 High"),
            AgentModel(id: "gpt-5.3-codex-high-fast", name: "Codex 5.3 High Fast"),
        ]).first
        #expect(family?.name == "Codex 5.3")
        #expect(family?.efforts == [nil, "high"])
        #expect(family?.modelID(effort: "max", fast: false) == "gpt-5.3-codex")
        #expect(family?.modelID(effort: nil, fast: true) == "gpt-5.3-codex")
        #expect(family?.modelID(effort: "high", fast: true) == "gpt-5.3-codex-high-fast")
    }

    @Test func claudeGetsEffortFlag() {
        let request = AgentRunRequest(prompt: "hi", workingDirectory: URL(fileURLWithPath: "/tmp"), model: "opus", effort: "xhigh", access: .editFiles, resumeSessionID: nil)
        let args = ClaudeProvider().invocation(for: request).arguments
        #expect(args.joined(separator: " ").contains("--effort xhigh"))
    }

    @Test func decodesSessionsWithoutEfforts() throws {
        var session = ChatSession(projectID: UUID(), agent: .claude)
        session.efforts[.claude] = "high"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        json.removeValue(forKey: "efforts")
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.efforts.isEmpty)
        #expect(decoded.id == session.id)
    }
}
