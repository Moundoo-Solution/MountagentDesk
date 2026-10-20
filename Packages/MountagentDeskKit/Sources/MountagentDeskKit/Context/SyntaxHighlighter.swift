import Foundation

/// The languages the file viewer colors, picked by file extension.
public enum CodeLanguage: String, Sendable, CaseIterable {
    case python, xml, javascript, typescript, json, swift, css, shell, yaml, sql, markdown, plain

    public init(fileName: String) {
        let lower = fileName.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "py", "pyi": self = .python
        case "xml", "html", "htm", "svg", "xsd", "plist", "csproj": self = .xml
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "ts", "tsx": self = .typescript
        case "json", "jsonc", "geojson": self = .json
        case "swift": self = .swift
        case "css", "scss", "less", "sass": self = .css
        case "sh", "bash", "zsh", "command": self = .shell
        case "yml", "yaml": self = .yaml
        case "sql": self = .sql
        case "md", "markdown", "mdc": self = .markdown
        default:
            switch lower {
            case ".zshrc", ".bashrc", ".profile", "dockerfile", "makefile": self = .shell
            default: self = .plain
            }
        }
    }

    public var title: String {
        switch self {
        case .python: "Python"
        case .xml: "XML"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .swift: "Swift"
        case .css: "CSS"
        case .shell: "Shell"
        case .yaml: "YAML"
        case .sql: "SQL"
        case .markdown: "Markdown"
        case .plain: "Plain Text"
        }
    }
}

/// A small regex highlighter: good enough to read code at a glance, not a parser.
/// Comments and strings are found first in one left-to-right pass (so `#` inside a string
/// stays a string); keywords, numbers and names are only colored outside them.
public enum SyntaxHighlighter {
    public enum Token: Sendable, Hashable {
        case keyword, string, comment, number, constant, function, type, decorator, tag, attribute, property
    }

    public struct Span: Sendable, Hashable {
        public var range: NSRange
        public var token: Token
    }

    public static func spans(in text: String, language: CodeLanguage) -> [Span] {
        guard let grammar = Grammar.for(language) else { return [] }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var spans: [Span] = []
        var protected = IndexSet()

        // 1. Comments and strings, whichever starts first wins.
        if let regions = grammar.regions {
            regions.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match else { return }
                for (index, token) in grammar.regionTokens.enumerated() where match.range(at: index + 1).location != NSNotFound {
                    let range = match.range(at: index + 1)
                    spans.append(Span(range: range, token: token))
                    protected.insert(integersIn: range.location..<(range.location + range.length))
                    break
                }
            }
        }

        // 2. Everything else, outside comments and strings.
        for rule in grammar.rules {
            rule.regex.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0,
                      !protected.intersects(integersIn: range.location..<(range.location + range.length))
                else { return }
                spans.append(Span(range: range, token: rule.token))
            }
        }
        return spans
    }

    // MARK: - Grammars

    private struct Rule {
        let regex: NSRegularExpression
        let token: Token
        var group = 0
    }

    private struct Grammar {
        /// One alternation; capture group i is `regionTokens[i - 1]`.
        var regions: NSRegularExpression?
        var regionTokens: [Token] = []
        var rules: [Rule] = []

        static func `for`(_ language: CodeLanguage) -> Grammar? {
            cache[language] ?? nil
        }

        private static let cache: [CodeLanguage: Grammar?] = {
            var result: [CodeLanguage: Grammar?] = [:]
            for language in CodeLanguage.allCases { result[language] = make(language) }
            return result
        }()

        private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // The patterns are constants; a typo should fail loudly in tests.
            try! NSRegularExpression(pattern: pattern, options: options)
        }

        private static func words(_ list: String, caseInsensitive: Bool = false) -> NSRegularExpression {
            let alternatives = list.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|")
            return regex("\\b(?:\(alternatives))\\b", caseInsensitive ? [.caseInsensitive] : [])
        }

        private static let doubleQuoted = #""(?:\\.|[^"\\\n])*""#
        private static let singleQuoted = #"'(?:\\.|[^'\\\n])*'"#
        private static let number = regex(#"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#)

        private static func cStyle(keywords: String, constants: String, extraStrings: String = "") -> Grammar {
            Grammar(
                regions: regex("(//[^\\n]*|/\\*[\\s\\S]*?\\*/)|(\(doubleQuoted)|\(singleQuoted)\(extraStrings))"),
                regionTokens: [.comment, .string],
                rules: [
                    Rule(regex: words(keywords), token: .keyword),
                    Rule(regex: words(constants), token: .constant),
                    Rule(regex: number, token: .number),
                    Rule(regex: regex(#"\b([A-Z][A-Za-z0-9_]*)\b"#), token: .type, group: 1),
                    Rule(regex: regex(#"\b([a-zA-Z_$][\w$]*)\s*(?=\()"#), token: .function, group: 1),
                    Rule(regex: regex(#"@[A-Za-z_][\w.]*"#), token: .decorator),
                ]
            )
        }

        private static func make(_ language: CodeLanguage) -> Grammar? {
            switch language {
            case .python:
                return Grammar(
                    regions: regex(#"(#[^\n]*)|((?i:[rbuf]{0,2})(?:"""[\s\S]*?"""|'''[\s\S]*?'''|"# + doubleQuoted + "|" + singleQuoted + "))"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"), token: .keyword),
                        Rule(regex: words("True False None self cls super"), token: .constant),
                        Rule(regex: number, token: .number),
                        Rule(regex: regex(#"^\s*(@[\w.]+)"#, [.anchorsMatchLines]), token: .decorator, group: 1),
                        Rule(regex: regex(#"\bdef\s+([A-Za-z_]\w*)"#), token: .function, group: 1),
                        Rule(regex: regex(#"\bclass\s+([A-Za-z_]\w*)"#), token: .type, group: 1),
                        Rule(regex: regex(#"\b([A-Za-z_]\w*)\s*(?==[^=])"#), token: .property, group: 1),
                    ]
                )
            case .xml:
                return Grammar(
                    regions: regex(#"(<!--[\s\S]*?-->)|("[^"]*"|'[^']*')"#),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: regex(#"</?([A-Za-z_][\w:.-]*)"#), token: .tag, group: 1),
                        Rule(regex: regex(#"\s([A-Za-z_][\w:.-]*)\s*(?==)"#), token: .attribute, group: 1),
                        Rule(regex: regex(#"&[#\w]+;"#), token: .constant),
                    ]
                )
            case .javascript, .typescript:
                return cStyle(
                    keywords: "async await break case catch class const continue debugger default delete do else export extends finally for from function if import in instanceof let new of return static super switch this throw try typeof var void while with yield interface type enum implements private public protected readonly declare namespace as",
                    constants: "true false null undefined NaN Infinity",
                    extraStrings: "|`(?:\\\\.|[^`\\\\])*`"
                )
            case .swift:
                return cStyle(
                    keywords: "actor associatedtype async await break case catch class continue default defer do else enum extension fallthrough fileprivate for func guard if import in init inout internal let nonisolated open operator private protocol public repeat rethrows return self Self some any static struct subscript super switch throw throws try typealias var where while weak",
                    constants: "true false nil"
                )
            case .json:
                return Grammar(
                    regions: regex(#"("(?:\\.|[^"\\\n])*"(?=\s*:))|("(?:\\.|[^"\\\n])*")"#),
                    regionTokens: [.property, .string],
                    rules: [
                        Rule(regex: words("true false null"), token: .constant),
                        Rule(regex: regex(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#), token: .number),
                    ]
                )
            case .css:
                return Grammar(
                    regions: regex("(/\\*[\\s\\S]*?\\*/|//[^\\n]*)|(\(doubleQuoted)|\(singleQuoted))"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: regex(#"([\w-]+)\s*(?=:[^:{]*[;}])"#), token: .property, group: 1),
                        Rule(regex: regex(#"(?:#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\b)"#), token: .number),
                        Rule(regex: regex(#"[.#][A-Za-z_][\w-]*"#), token: .type),
                        Rule(regex: regex(#"[$@][\w-]+"#), token: .decorator),
                    ]
                )
            case .shell:
                return Grammar(
                    regions: regex("((?<![\\w$])#[^\\n]*)|(\(doubleQuoted)|'[^']*')"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: words("if then else elif fi for in do done while until case esac function return local export set unset source exit"), token: .keyword),
                        Rule(regex: regex(#"\$\{?[\w@#?*!-]+\}?"#), token: .decorator),
                        Rule(regex: regex(#"(?<=\s|^)--?[\w-]+"#, [.anchorsMatchLines]), token: .attribute),
                    ]
                )
            case .yaml:
                return Grammar(
                    regions: regex("((?<!\\S)#[^\\n]*)|(\(doubleQuoted)|\(singleQuoted))"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: regex(#"^\s*-?\s*([\w.\-/ ]+?)\s*(?=:(?:\s|$))"#, [.anchorsMatchLines]), token: .property, group: 1),
                        Rule(regex: words("true false null yes no on off"), token: .constant),
                        Rule(regex: number, token: .number),
                        Rule(regex: regex(#"[&*][\w-]+"#), token: .decorator),
                    ]
                )
            case .sql:
                return Grammar(
                    regions: regex("(--[^\\n]*|/\\*[\\s\\S]*?\\*/)|(\(singleQuoted))"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: words("select from where and or not in is null join left right inner outer full on group by order having limit offset insert into values update set delete create table alter drop index as distinct union all case when then else end exists between like ilike returning with", caseInsensitive: true), token: .keyword),
                        Rule(regex: number, token: .number),
                        Rule(regex: regex(#"\b([A-Za-z_]\w*)\s*(?=\()"#), token: .function, group: 1),
                    ]
                )
            case .markdown:
                return Grammar(
                    regions: regex("(<!--[\\s\\S]*?-->)|(```[\\s\\S]*?```|`[^`\\n]+`)"),
                    regionTokens: [.comment, .string],
                    rules: [
                        Rule(regex: regex(#"^#{1,6} .*$"#, [.anchorsMatchLines]), token: .keyword),
                        Rule(regex: regex(#"\*\*[^*\n]+\*\*"#), token: .type),
                        Rule(regex: regex(#"^\s*(?:[-*+]|\d+\.)\s"#, [.anchorsMatchLines]), token: .decorator),
                        Rule(regex: regex(#"\[[^\]\n]+\]\([^)\n]+\)"#), token: .attribute),
                    ]
                )
            case .plain:
                return nil
            }
        }
    }
}
