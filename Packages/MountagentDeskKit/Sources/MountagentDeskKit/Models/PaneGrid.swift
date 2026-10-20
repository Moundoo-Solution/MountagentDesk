import Foundation

/// The chat area split into panes, each showing one session: which split, which session
/// sits in which pane, and which pane has focus. A session is shown in one pane at most.
public struct PaneGrid: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        /// One pane.
        case single
        /// Two panes side by side.
        case columns
        /// Two panes, one above the other.
        case rows
        /// Four panes, 2×2.
        case grid

        public var paneCount: Int {
            switch self {
            case .single: 1
            case .columns, .rows: 2
            case .grid: 4
            }
        }
    }

    public static let maxPanes = 4

    public private(set) var layout: Layout = .single
    /// One slot per possible pane; slots past the layout's count keep their session for
    /// when the split grows again.
    public private(set) var slots: [UUID?] = Array(repeating: nil, count: maxPanes)
    public private(set) var focused = 0

    public init() {}

    /// The sessions in the panes on screen, in reading order.
    public var visible: [UUID?] { Array(slots.prefix(layout.paneCount)) }
    public var focusedSession: UUID? { slots[focused] }

    public func pane(showing id: UUID) -> Int? {
        visible.firstIndex(of: id)
    }

    /// Shows a session in the focused pane, or focuses the pane already showing it.
    public mutating func open(_ id: UUID?) {
        guard let id else {
            slots[focused] = nil
            return
        }
        if let pane = pane(showing: id) {
            focused = pane
            return
        }
        clearHidden(id)
        slots[focused] = id
    }

    /// Shows a session in a given pane (a drop). If another pane shows it, the two swap.
    public mutating func open(_ id: UUID, inPane index: Int) {
        guard visible.indices.contains(index) else { return }
        if let other = pane(showing: id), other != index {
            slots.swapAt(other, index)
        } else {
            clearHidden(id)
            slots[index] = id
        }
        focused = index
    }

    public mutating func focus(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        focused = index
    }

    /// Changes the split. The focused session stays on screen: when the split shrinks past
    /// it, it moves into the last pane that remains.
    public mutating func setLayout(_ newLayout: Layout) {
        let count = newLayout.paneCount
        if focused >= count {
            slots.swapAt(focused, count - 1)
            focused = count - 1
        }
        layout = newLayout
    }

    /// Empties a pane, e.g. its close button.
    public mutating func clear(pane index: Int) {
        guard slots.indices.contains(index) else { return }
        slots[index] = nil
    }

    /// Forgets a deleted session everywhere.
    public mutating func remove(_ id: UUID) {
        for index in slots.indices where slots[index] == id { slots[index] = nil }
    }

    /// Drops sessions that no longer exist (after loading a saved grid).
    public mutating func keep(only existing: Set<UUID>) {
        for index in slots.indices where slots[index].map({ !existing.contains($0) }) == true {
            slots[index] = nil
        }
        if !visible.indices.contains(focused) { focused = 0 }
    }

    private mutating func clearHidden(_ id: UUID) {
        for index in slots.indices where index >= layout.paneCount && slots[index] == id {
            slots[index] = nil
        }
    }

    // Codable with defaults, so a damaged or older saved grid still loads.
    private enum CodingKeys: String, CodingKey { case layout, slots, focused }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layout = (try? container.decode(Layout.self, forKey: .layout)) ?? .single
        var saved = (try? container.decode([UUID?].self, forKey: .slots)) ?? []
        saved = Array(saved.prefix(Self.maxPanes))
        slots = saved + Array(repeating: nil, count: Self.maxPanes - saved.count)
        focused = min(max(0, (try? container.decode(Int.self, forKey: .focused)) ?? 0), layout.paneCount - 1)
    }
}
