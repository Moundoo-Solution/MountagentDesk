import Foundation

/// Reasoning effort, as the CLIs name it (`--effort`, Codex's `model_reasoning_effort`).
public enum Effort {
    public static let levels = ["low", "medium", "high", "xhigh", "max"]

    public static func name(_ id: String?) -> String {
        switch id {
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "Extra High"
        case "max": "Max"
        case let other?: other.capitalized
        case nil: "Default"
        }
    }
}

/// One model with its effort and speed variants. cursor-agent lists every combination
/// as its own model id (`gpt-5.3-codex-high-fast`); this folds them back into one choice
/// plus an effort and a Fast switch, the way Cursor's own picker shows them.
public struct ModelFamily: Identifiable, Hashable, Sendable {
    public struct Variant: Hashable, Sendable {
        public var effort: String?
        public var fast: Bool
        public var modelID: String?
    }

    public var id: String
    public var name: String
    public var variants: [Variant]
    /// The effort Cursor uses when none is named (the variant whose title has no effort word).
    public var defaultEffort: String?

    /// Efforts offered, low to max; `nil` stands for a variant without an effort suffix.
    public var efforts: [String?] {
        var seen: [String?] = []
        for variant in variants where !seen.contains(variant.effort) {
            seen.append(variant.effort)
        }
        return seen.sorted { (Effort.levels.firstIndex(of: $0 ?? "") ?? -1) < (Effort.levels.firstIndex(of: $1 ?? "") ?? -1) }
    }

    public var hasEffort: Bool { efforts.count > 1 }
    public var hasFast: Bool { variants.contains(where: \.fast) && variants.contains { !$0.fast } }

    public func variant(for modelID: String?) -> Variant? {
        variants.first { $0.modelID == modelID }
    }

    /// The model id for an effort and speed, falling back to the nearest variant that exists.
    public func modelID(effort: String?, fast: Bool) -> String? {
        let wanted = efforts.contains(effort) ? effort : defaultEffort
        return (variants.first { $0.effort == wanted && $0.fast == fast }
            ?? variants.first { $0.effort == wanted }
            ?? variants.first { $0.effort == defaultEffort && !$0.fast }
            ?? variants.first)?.modelID
    }
}

public enum ModelCatalog {
    /// Groups cursor-agent's flat model list into families, keeping the list's order.
    public static func cursorFamilies(from models: [AgentModel]) -> [ModelFamily] {
        var order: [String] = []
        var grouped: [String: [(AgentModel, ModelFamily.Variant)]] = [:]
        for model in models {
            let (base, effort, fast) = split(model.id)
            if grouped[base] == nil { order.append(base) }
            grouped[base, default: []].append((model, ModelFamily.Variant(effort: effort, fast: fast, modelID: model.id)))
        }
        return order.map { base in
            let members = grouped[base] ?? []
            // The plain-named, non-fast variant is the default ("Claude Opus 5.5 1M" is medium).
            let plain = members.first { !$0.1.fast && !mentionsEffort($0.0.name) }
            let title = stripVariantWords(plain?.0.name ?? members.first?.0.name ?? base)
            return ModelFamily(
                id: base,
                name: title,
                variants: members.map(\.1),
                defaultEffort: plain?.1.effort ?? members.first { !$0.1.fast }?.1.effort ?? members.first?.1.effort
            )
        }
    }

    /// `claude-opus-5-5-high-fast` → (`claude-opus-5-5`, `high`, true). `nil` (Auto) → (`auto`, nil, false).
    public static func split(_ id: String?) -> (base: String, effort: String?, fast: Bool) {
        guard var rest = id else { return ("auto", nil, false) }
        var fast = false
        if rest.hasSuffix("-fast") {
            fast = true
            rest.removeLast("-fast".count)
        }
        for level in Effort.levels where rest.hasSuffix("-" + level) {
            return (String(rest.dropLast(level.count + 1)), level, fast)
        }
        return (rest, nil, fast)
    }

    private static let effortWords = ["Extra High", "Medium", "High", "Low", "Max"]

    static func mentionsEffort(_ name: String) -> Bool {
        let words = " " + clean(name) + " "
        return effortWords.contains { words.contains(" \($0) ") }
    }

    static func stripVariantWords(_ name: String) -> String {
        var words = " " + clean(name) + " "
        for word in effortWords + ["Fast"] {
            words = words.replacingOccurrences(of: " \(word) ", with: " ")
        }
        return words.split(separator: " ").joined(separator: " ")
    }

    private static func clean(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{200B}", with: "")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
