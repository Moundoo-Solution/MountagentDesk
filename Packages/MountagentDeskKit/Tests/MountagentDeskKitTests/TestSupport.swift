import Foundation
import Testing
@testable import MountagentDeskKit

/// The non-empty lines of a recorded `Fixtures/<name>.jsonl`.
func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.isEmpty }
}

/// Feeds recorded lines through a parser into a fresh session, as the app does.
/// The process then exits with `exitStatus`.
func replay(_ lines: [String], parser: some AgentStreamParser, agent: AgentKind, exitStatus: Int32 = 0) -> (ChatSession, TranscriptReducer) {
    var parser = parser
    var reducer = TranscriptReducer(agent: agent)
    var session = ChatSession(projectID: UUID(), agent: agent)
    var completed = false
    for line in lines {
        for event in parser.parse(line: line) {
            if case .completed = event { completed = true }
            reducer.apply(event, to: &session)
        }
    }
    if !completed {
        for event in parser.finish(exitStatus: exitStatus) { reducer.apply(event, to: &session) }
    }
    return (session, reducer)
}
