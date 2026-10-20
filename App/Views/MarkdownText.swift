import MountagentDeskKit
import AppKit
import SwiftUI

/// Renders the Markdown agents usually write (headings, lists, fenced code, inline styling)
/// into one AppKit text view, so a whole reply selects like a document: drag across
/// paragraphs, double-click a word, triple-click a paragraph, shift-click to extend, ⌘C.
struct MarkdownText: View {
    private let text: String

    init(_ text: String) {
        // Rename markers are applied when the turn ends; don't flash them while streaming.
        self.text = SessionTitle.extract(from: text).text
    }

    var body: some View {
        SelectableText(markdown: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct ListItem {
        var marker: String
        var text: String
        var indent: Int
    }

    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case list([ListItem])
        case code(String, String)
    }

    nonisolated static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var code: [String]?
        var language = ""

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language, lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    flushList()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if let heading = trimmed.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                flushParagraph()
                flushList()
                blocks.append(.heading(heading.1.count, String(heading.2)))
            } else if let bullet = line.wholeMatch(of: /(\s*)([-*•]|\d+[.)])\s+(.+)/) {
                flushParagraph()
                let marker = String(bullet.2)
                list.append(ListItem(
                    marker: marker.first?.isNumber == true ? marker : "•",
                    text: String(bullet.3),
                    indent: bullet.1.count / 2
                ))
            } else if trimmed.isEmpty {
                flushParagraph()
                flushList()
            } else if !list.isEmpty, line.hasPrefix("  ") {
                // A wrapped list item.
                list[list.count - 1].text += " " + trimmed
            } else {
                flushList()
                paragraph.append(line)
            }
        }
        // An unclosed fence is still streaming in; show what has arrived.
        if let lines = code { blocks.append(.code(language, lines.joined(separator: "\n"))) }
        flushParagraph()
        flushList()
        return blocks
    }
}

// MARK: - Attributed rendering

/// Builds the attributed string for a reply. Colors are dynamic, so one string serves both
/// appearances.
enum MarkdownRenderer {
    static let bodySize: CGFloat = 14

    static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let blocks = MarkdownText.parse(markdown)
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            switch block {
            case .paragraph(let text):
                output.append(inline(text, paragraph: paragraphStyle(spacingAfter: isLast ? 0 : 10)))
            case .heading(let level, let text):
                let size: CGFloat = level == 1 ? 18 : level == 2 ? 16 : 14
                let style = paragraphStyle(spacingAfter: 6, spacingBefore: index == 0 ? 0 : 8)
                output.append(inline(text, paragraph: style, baseFont: .systemFont(ofSize: size, weight: .semibold)))
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    let lastItem = itemIndex == items.count - 1
                    if itemIndex > 0 { appendNewline(to: output) }
                    output.append(listItem(item, spacingAfter: lastItem ? (isLast ? 0 : 10) : 4))
                }
            case .code(let language, let code):
                output.append(codeBlock(language: language, code: code, spacingAfter: isLast ? 0 : 10))
            }
            if !isLast { appendNewline(to: output) }
        }
        return output
    }

    /// Ends the current paragraph. The newline carries that paragraph's style, since a
    /// paragraph's spacing and block come from its terminating character too.
    private static func appendNewline(to output: NSMutableAttributedString) {
        var attributes = output.length > 0 ? output.attributes(at: output.length - 1, effectiveRange: nil) : [:]
        // Run decorations on a newline would paint to the end of the line.
        for key in [NSAttributedString.Key.backgroundColor, .link, .strikethroughStyle, .underlineStyle] {
            attributes.removeValue(forKey: key)
        }
        output.append(NSAttributedString(string: "\n", attributes: attributes))
    }

    private static func paragraphStyle(spacingAfter: CGFloat, spacingBefore: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = spacingAfter
        style.paragraphSpacingBefore = spacingBefore
        return style
    }

    private static func listItem(_ item: MarkdownText.ListItem, spacingAfter: CGFloat) -> NSAttributedString {
        let indent = CGFloat(item.indent) * 18
        let markerWidth: CGFloat = item.marker == "•" ? 16 : 22
        let style = paragraphStyle(spacingAfter: spacingAfter)
        style.firstLineHeadIndent = indent + 4
        style.headIndent = indent + 4 + markerWidth
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 4 + markerWidth)]
        let line = NSMutableAttributedString(string: item.marker + "\t", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: bodySize, weight: .regular),
            .foregroundColor: Palette.textSecondary,
            .paragraphStyle: style,
        ])
        line.append(inline(item.text, paragraph: style))
        return line
    }

    /// Code lines are indented and marked with `.codeBlock`; `CodeBlockLayoutManager` paints
    /// the rounded box behind them. The first and last lines get extra spacing so the box's
    /// padding never overlaps neighbouring text.
    private static func codeBlock(language: String, code: String, spacingAfter: CGFloat) -> NSAttributedString {
        let id = UUID().uuidString
        var lines = (code.isEmpty ? " " : code).components(separatedBy: "\n")
        if !language.isEmpty { lines.insert(language, at: 0) }

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let isCaption = index == 0 && !language.isEmpty
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = CodeBlockLayoutManager.padding
            style.headIndent = CodeBlockLayoutManager.padding
            style.tailIndent = -CodeBlockLayoutManager.padding
            style.lineSpacing = 2
            style.paragraphSpacingBefore = index == 0 ? CodeBlockLayoutManager.padding + 4 : 0
            style.paragraphSpacing = index == lines.count - 1 ? CodeBlockLayoutManager.padding + spacingAfter : (isCaption ? 4 : 0)
            result.append(NSAttributedString(string: line + (index == lines.count - 1 ? "" : "\n"), attributes: [
                .font: isCaption ? NSFont.systemFont(ofSize: 11) : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isCaption ? Palette.textTertiary : Palette.textPrimary,
                .paragraphStyle: style,
                .codeBlock: id,
            ]))
        }
        return result
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) on top of a base font.
    static func inline(_ text: String, paragraph: NSParagraphStyle, baseFont: NSFont = .systemFont(ofSize: bodySize)) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var font = baseFont
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Palette.textPrimary,
                .paragraphStyle: paragraph,
            ]
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize - 1.5, weight: .regular)
                attributes[.backgroundColor] = Palette.inlineCode
                attributes[.foregroundColor] = Palette.inlineCodeText
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = baseFont.fontDescriptor.withSymbolicTraits(baseFont.fontDescriptor.symbolicTraits.union(traits))
                    font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
                }
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = Palette.accent
            }
            attributes[.font] = font
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

/// The theme's tokens as dynamic NSColors, for AppKit text.
enum Palette {
    private static func ink(_ alpha: CGFloat) -> NSColor { Theme.inkColor(alpha) }
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor { .dynamic(light: light, dark: dark) }

    static let textPrimary = ink(0.92)
    static let textSecondary = ink(0.55)
    static let textTertiary = ink(0.37)
    static let hairline = ink(0.08)
    /// Inline code: a faint rose wash with rose text, so paths and identifiers stand out.
    static let inlineCode = dynamic(light: NSColor(hex: 0xB4365A, alpha: 0.07), dark: NSColor(hex: 0xF06595, alpha: 0.10))
    static let inlineCodeText = dynamic(light: NSColor(hex: 0xB4365A), dark: NSColor(hex: 0xF0A0B8))
    static let codeBackground = dynamic(light: NSColor(hex: Theme.Hex.sidebarLight), dark: NSColor(hex: Theme.Hex.sidebarDark))
    static let accent = dynamic(light: NSColor(hex: Theme.Hex.accentLight), dark: NSColor(hex: Theme.Hex.accentDark))
    static let selection = dynamic(light: NSColor(hex: Theme.Hex.accentLight, alpha: 0.22), dark: NSColor(hex: Theme.Hex.accentDark, alpha: 0.30))
}

extension NSAttributedString.Key {
    /// Marks the characters of one fenced code block (value: the block's id).
    static let codeBlock = NSAttributedString.Key("MountagentDeskCodeBlock")
}

/// Paints a rounded box behind each run of `.codeBlock` text, spanning the container width.
final class CodeBlockLayoutManager: NSLayoutManager {
    static let padding: CGFloat = 10

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first, storage.length > 0 {
            let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            var painted = Set<String>()
            storage.enumerateAttribute(.codeBlock, in: characters) { value, range, _ in
                guard let id = value as? String, painted.insert(id).inserted else { return }
                var whole = NSRange()
                _ = storage.attribute(.codeBlock, at: range.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: storage.length))
                let glyphs = glyphRange(forCharacterRange: whole, actualCharacterRange: nil)
                var box = boundingRect(forGlyphRange: glyphs, in: container)
                box.origin.x = 0
                box.size.width = container.size.width
                box = box.insetBy(dx: 0, dy: -Self.padding + 2).offsetBy(dx: origin.x, dy: origin.y)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
                Palette.codeBackground.setFill()
                path.fill()
                Palette.hairline.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

// MARK: - Text view

/// A read-only, selectable NSTextView that sizes to its content's height.
private struct SelectableText: NSViewRepresentable {
    let markdown: String

    final class Coordinator {
        var rendered: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1 with a layout manager that paints code-block boxes.
        let storage = NSTextStorage()
        let layout = CodeBlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let view = NSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.selectedTextAttributes = [.backgroundColor: Palette.selection]
        view.linkTextAttributes = [.foregroundColor: Palette.accent, .cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard context.coordinator.rendered != markdown else { return }
        context.coordinator.rendered = markdown
        let selection = view.selectedRanges
        view.textStorage?.setAttributedString(MarkdownRenderer.render(markdown))
        // Keep a selection made while the reply is still streaming in.
        let length = view.textStorage?.length ?? 0
        view.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= length }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 600)
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        return CGSize(width: width, height: height)
    }
}
