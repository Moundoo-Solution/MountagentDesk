import Foundation

/// Applies agent events to a session's transcript. Holds the per-turn state of which
/// rows are still open for streaming; make one per turn.
public struct TranscriptReducer: Sendable {
    public let agent: AgentKind
    private var openTextID: UUID?
    private var openThinkingID: UUID?
    /// Index of the first item this turn added, so the turn can be tidied when it ends.
    private var turnStart: Int?
    public private(set) var lastResult: TurnResult?

    public init(agent: AgentKind) {
        self.agent = agent
    }

    public mutating func apply(_ event: AgentEvent, to session: inout ChatSession) {
        session.updatedAt = .now
        if turnStart == nil { turnStart = session.items.count }
        switch event {
        case .sessionStarted(let id, _):
            session.agentSessionIDs[agent] = id

        case .textBlockStarted:
            openTextID = nil
            openThinkingID = nil

        case .textDelta(let text):
            openThinkingID = nil
            mutateOpenText(in: &session) { $0 += text }

        case .textSnapshot(let text):
            openThinkingID = nil
            mutateOpenText(in: &session) { $0 = text }

        case .thinkingDelta(let text):
            // Claude streams empty deltas when its thinking is redacted.
            guard !text.isEmpty else { break }
            if let id = openThinkingID, let index = session.items.firstIndex(where: { $0.id == id }) {
                session.items[index].text += text
            } else {
                openTextID = nil
                let item = ChatItem(kind: .thinking, agent: agent, text: text)
                openThinkingID = item.id
                session.items.append(item)
            }

        case .toolStarted(let id, let name, let summary):
            openTextID = nil
            openThinkingID = nil
            session.items.append(ChatItem(kind: .tool, agent: agent, text: summary, toolCallID: id, toolName: name, toolStatus: .running))

        case .toolFinished(let id, let output, let isError):
            if let index = session.items.lastIndex(where: { $0.toolCallID == id }) {
                session.items[index].toolOutput = output.truncated(to: 20_000)
                session.items[index].toolStatus = isError ? .failed : .succeeded
            }

        case .permissionRequest(let request):
            openTextID = nil
            openThinkingID = nil
            session.items.append(ChatItem(
                kind: .permission, agent: agent, text: request.summary,
                toolCallID: request.id, toolName: request.toolName, toolOutput: request.detail,
                permissionState: .pending, permissionRule: request.alwaysRule
            ))

        case .toolBlocked(let blocked):
            openTextID = nil
            openThinkingID = nil
            session.items.append(ChatItem(
                kind: .permission, agent: agent, text: blocked.summary,
                toolCallID: blocked.callID, toolName: blocked.toolName,
                permissionState: .blocked, permissionRule: blocked.rule
            ))

        case .reply, .rateLimit:
            break

        case .completed(let result):
            openTextID = nil
            openThinkingID = nil
            lastResult = result
            finishRunningTools(in: &session)
            applyTitleMarkers(in: &session)
            // A failed turn often carries its reason only in the result text.
            if result.isError, let text = result.text, !text.isEmpty,
               !session.items.contains(where: { $0.kind == .assistant && $0.text == text }) {
                session.items.append(ChatItem(kind: .notice, agent: agent, text: text, isError: true))
            }

        case .failure(let message):
            openTextID = nil
            openThinkingID = nil
            finishRunningTools(in: &session)
            applyTitleMarkers(in: &session)
            session.items.append(ChatItem(kind: .notice, agent: agent, text: message, isError: message != AgentRun.stoppedMessage))
        }
    }

    private mutating func mutateOpenText(in session: inout ChatSession, _ change: (inout String) -> Void) {
        if let id = openTextID, let index = session.items.firstIndex(where: { $0.id == id }) {
            change(&session.items[index].text)
        } else {
            var text = ""
            change(&text)
            let item = ChatItem(kind: .assistant, agent: agent, text: text)
            openTextID = item.id
            session.items.append(item)
        }
    }

    private func finishRunningTools(in session: inout ChatSession) {
        for index in session.items.indices {
            if session.items[index].toolStatus == .running {
                session.items[index].toolStatus = .failed
            }
            if session.items[index].permissionState == .pending {
                session.items[index].permissionState = .expired
            }
        }
    }

    /// Applies and removes `Mountagent-Title:` lines the agent wrote this turn.
    private func applyTitleMarkers(in session: inout ChatSession) {
        let start = min(turnStart ?? session.items.count, session.items.count)
        for index in session.items.indices[start...] where session.items[index].kind == .assistant {
            let (text, title) = SessionTitle.extract(from: session.items[index].text)
            guard let title else { continue }
            session.items[index].text = text
            session.title = title
        }
        session.items.removeAll { $0.kind == .assistant && $0.text.isEmpty }
    }
}

/// Builds the prompt sent to an agent, including what it needs to pick up a conversation
/// another agent started.
public enum PromptBuilder {
    public static func prompt(_ text: String, attachments: [String], missed: [ChatItem]) -> String {
        var parts: [String] = []
        if let transcript = handoffTranscript(missed) {
            parts.append("""
            <previous_conversation>
            Part of this conversation happened with another coding agent in the same project. \
            Here is what you missed, so you can continue from it.

            \(transcript)
            </previous_conversation>
            """)
        }
        parts.append(text)
        if !attachments.isEmpty {
            parts.append("Files to look at:\n" + attachments.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The most recent turns, oldest first, capped so the handoff stays cheap.
    static func handoffTranscript(_ items: [ChatItem], limit: Int = 12_000) -> String? {
        var lines: [String] = []
        var size = 0
        for item in items.reversed() {
            let line: String
            switch item.kind {
            case .user:
                let images = item.images ?? []
                line = "User: \(item.text)" + (images.isEmpty ? "" : " [with \(images.count) image(s): \(images.joined(separator: ", "))]")
            case .assistant: line = "\(item.agent?.displayName ?? "Assistant"): \(item.text)"
            case .tool: line = "[\(item.toolName ?? "Tool")] \(item.text)"
            case .thinking, .notice, .permission: continue
            }
            size += line.count
            if size > limit { break }
            lines.append(line)
        }
        return lines.isEmpty ? nil : lines.reversed().joined(separator: "\n")
    }

    /// A short title from the first prompt.
    public static func title(from prompt: String) -> String {
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines).firstLine
        return line.isEmpty ? "New session" : line.truncated(to: 48)
    }
}
