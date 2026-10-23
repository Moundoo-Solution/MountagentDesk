import Foundation

/// One conversation inside a project. A session can switch agent between turns; each
/// agent keeps its own CLI session id so it can resume its own context.
public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var agent: AgentKind
    /// Selected model per agent; a missing entry means the CLI default.
    public var models: [AgentKind: String]
    /// Reasoning effort per agent, for CLIs that take it as an option (Claude, Codex,
    /// Antigravity). Cursor encodes effort in the model id instead.
    public var efforts: [AgentKind: String]
    public var access: AccessLevel
    /// The CLI's own session id per agent, used for `--resume`.
    public var agentSessionIDs: [AgentKind: String]
    /// How many transcript items each agent had seen when its last turn ended.
    public var seenCounts: [AgentKind: Int]
    public var items: [ChatItem]
    /// The branch the main folder was on when this session last ran a turn.
    public var branch: String?
    /// Kept, but out of the sidebar's list.
    public var archived = false
    /// The session's own working copy (`GitWorktree`), where its agents run instead of the
    /// project's main folder, and that copy's branch.
    public var worktree: String?
    public var worktreeBranch: String?
    /// Set for a terminal session: the command it runs in its folder instead of an agent
    /// (empty: the login shell).
    public var command: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        title: String = "New session",
        agent: AgentKind,
        access: AccessLevel = .editFiles,
        createdAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.agent = agent
        self.models = [:]
        self.efforts = [:]
        self.access = access
        self.agentSessionIDs = [:]
        self.seenCounts = [:]
        self.items = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var model: String? {
        get { models[agent] }
        set { models[agent] = newValue }
    }

    public var effort: String? {
        get { efforts[agent] }
        set { efforts[agent] = newValue }
    }

    public var isTerminal: Bool { command != nil }

    // Sessions saved by earlier versions lack the newer fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decode(UUID.self, forKey: .projectID)
        title = try container.decode(String.self, forKey: .title)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        models = try Self.perAgent(String.self, in: container, forKey: .models)
        efforts = try Self.perAgent(String.self, in: container, forKey: .efforts)
        access = try container.decodeIfPresent(AccessLevel.self, forKey: .access) ?? .editFiles
        agentSessionIDs = try Self.perAgent(String.self, in: container, forKey: .agentSessionIDs)
        seenCounts = try Self.perAgent(Int.self, in: container, forKey: .seenCounts)
        // One row this version can't read (a newer kind, say) mustn't hide the whole session.
        items = try container.decodeIfPresent([Lossy<ChatItem>].self, forKey: .items)?.compactMap(\.value) ?? []
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
        worktreeBranch = try container.decodeIfPresent(String.self, forKey: .worktreeBranch)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// A per-agent dictionary, dropping entries for agents this version doesn't know.
    private static func perAgent<Value: Decodable, Key: CodingKey>(_ type: Value.Type, in container: KeyedDecodingContainer<Key>, forKey key: Key) throws -> [AgentKind: Value] {
        let raw = try container.decodeIfPresent([String: Value].self, forKey: key) ?? [:]
        return Dictionary(raw.compactMap { name, value in AgentKind(stored: name).map { ($0, value) } }) { first, _ in first }
    }

    /// A new session holding this one's transcript up to and including `itemID`. The agents
    /// start fresh CLI sessions and are handed the transcript on the next message.
    public func forked(through itemID: UUID, at date: Date = .now) -> ChatSession {
        var copy = ChatSession(projectID: projectID, title: "Fork of \(title)", agent: agent, access: access, createdAt: date)
        copy.models = models
        copy.efforts = efforts
        let end = items.firstIndex { $0.id == itemID }.map { $0 + 1 } ?? items.count
        copy.items = items[..<end].map { item in
            var item = item
            item.id = UUID()
            if item.permissionState == .pending { item.permissionState = .expired }
            return item
        }
        return copy
    }

    /// Turns the other agent handled since this agent last spoke, which it must be told
    /// about. Empty when nothing was missed.
    public func unseenItems(for agent: AgentKind) -> [ChatItem] {
        let seen = agentSessionIDs[agent] == nil ? 0 : min(seenCounts[agent] ?? 0, items.count)
        let missed = Array(items[seen...])
        return missed.contains { $0.kind == .user } ? missed : []
    }
}

/// One row of the transcript.
public struct ChatItem: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user
        case assistant
        case thinking
        case tool
        case permission
        case notice
    }

    public enum ToolStatus: String, Codable, Sendable {
        case running
        case succeeded
        case failed
    }

    public var id: UUID
    public var kind: Kind
    /// Which agent produced the item (nil for user rows and app notices).
    public var agent: AgentKind?
    public var text: String
    public var date: Date

    // Tool rows
    public var toolCallID: String?
    public var toolName: String?
    public var toolOutput: String?
    public var toolStatus: ToolStatus?

    // Permission rows (toolCallID holds the request or call id, toolOutput the input)
    public var permissionState: PermissionState?
    /// The rule "Always allow" saves.
    public var permissionRule: String?

    // Notice rows
    public var isError: Bool

    // User rows
    public var attachments: [String]

    /// The user's thumbs up (1) or down (-1) on an assistant reply.
    public var rating: Int?

    /// Images sent with a user message (paths in Mountagent Desk's attachments folder).
    public var images: [String]?

    /// On a user row: the git checkpoint of the main folder taken before the agent's turn
    /// (`GitCheckpoint`). On a "reverted" notice: the state just before the revert.
    public var checkpoint: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        agent: AgentKind? = nil,
        text: String,
        date: Date = .now,
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolOutput: String? = nil,
        toolStatus: ToolStatus? = nil,
        permissionState: PermissionState? = nil,
        permissionRule: String? = nil,
        isError: Bool = false,
        attachments: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.agent = agent
        self.text = text
        self.date = date
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolOutput = toolOutput
        self.toolStatus = toolStatus
        self.permissionState = permissionState
        self.permissionRule = permissionRule
        self.isError = isError
        self.attachments = attachments
    }
}

/// Decodes a value or nothing, so one bad element doesn't fail its array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
