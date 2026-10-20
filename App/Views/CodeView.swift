import MountagentDeskKit
import AppKit
import SwiftUI

/// A read-only code editor view: line-number gutter, syntax colors, no wrapping (unless
/// asked), selection and ⌘F find, top-left aligned like any editor.
struct CodeView: NSViewRepresentable {
    let text: String
    let language: CodeLanguage
    var wraps = false
    /// Caret line and column (1-based), for a status bar.
    var position: Binding<CodePosition>?

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Take exactly the space offered: the text view is as wide as the longest line, and
    /// letting that through would push the whole panel past its edges.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CodeContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> CodeContainer {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = CodePalette.background
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.selectedTextAttributes = [.backgroundColor: CodePalette.selection]
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CodePalette.background
        scrollView.borderType = .noBorder

        let gutter = LineNumberGutter(textView: textView, scrollView: scrollView)
        context.coordinator.textView = textView
        context.coordinator.ruler = gutter
        return CodeContainer(gutter: gutter, scrollView: scrollView)
    }

    func updateNSView(_ container: CodeContainer, context: Context) {
        let scrollView = container.scrollView
        let coordinator = context.coordinator
        coordinator.position = position
        guard let textView = coordinator.textView else { return }
        if coordinator.wraps != wraps {
            coordinator.wraps = wraps
            setWrapping(wraps, textView: textView, in: scrollView)
        }
        if coordinator.text != text || coordinator.language != language {
            coordinator.text = text
            coordinator.language = language
            textView.textStorage?.setAttributedString(Self.highlighted(text, language: language))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.ruler?.textDidChange()
            // After layout settles (the gutter may have widened), start at the top-left.
            DispatchQueue.main.async {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private func setWrapping(_ wraps: Bool, textView: NSTextView, in scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wraps {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        }
        scrollView.hasHorizontalScroller = !wraps
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
    }

    static func highlighted(_ text: String, language: CodeLanguage) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.defaultTabInterval = 28
        paragraph.tabStops = []
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: CodePalette.font,
            .foregroundColor: CodePalette.text,
            .paragraphStyle: paragraph,
        ])
        for span in SyntaxHighlighter.spans(in: text, language: language) {
            result.addAttribute(.foregroundColor, value: CodePalette.color(for: span.token), range: span.range)
            if span.token == .comment {
                result.addAttribute(.font, value: CodePalette.italicFont, range: span.range)
            }
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var ruler: LineNumberGutter?
        var text: String?
        var language: CodeLanguage?
        var wraps: Bool?
        var position: Binding<CodePosition>?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, let position else { return }
            let string = textView.string as NSString
            let caret = min(textView.selectedRange().location, string.length)
            let lineRange = string.lineRange(for: NSRange(location: caret, length: 0))
            var line = 1
            string.enumerateSubstrings(in: NSRange(location: 0, length: lineRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
            position.wrappedValue = CodePosition(line: line, column: caret - lineRange.location + 1, selected: textView.selectedRange().length)
            ruler?.needsDisplay = true
        }
    }
}

struct CodePosition: Equatable {
    var line = 1
    var column = 1
    var selected = 0
}

/// The gutter on the left and the scrolling text beside it. The gutter is its own view
/// (not an NSRulerView, which mis-tiles inside SwiftUI) and follows the vertical scroll.
final class CodeContainer: NSView {
    let gutter: LineNumberGutter
    let scrollView: NSScrollView

    init(gutter: LineNumberGutter, scrollView: NSScrollView) {
        self.gutter = gutter
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
        gutter.onWidthChange = { [weak self] in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let width = gutter.width
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }
}

/// Line numbers, right-aligned, with the caret's line brighter.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    /// UTF-16 offset where each line starts.
    private var lineStarts: [Int] = [0]
    private(set) var width: CGFloat = 44
    var onWidthChange: (() -> Void)?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func scrolled(_ note: Notification) { needsDisplay = true }

    func textDidChange() {
        let string = (textView?.string ?? "") as NSString
        var starts = [0]
        var index = 0
        while index < string.length {
            index = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
            if index < string.length || string.character(at: string.length - 1) == 10 { starts.append(index) }
        }
        lineStarts = starts
        let digits = max(3, String(starts.count).count)
        let newWidth = CGFloat(digits) * 7.5 + 22
        if newWidth != width {
            width = newWidth
            onWidthChange?()
        }
        needsDisplay = true
    }

    private func lineNumber(at offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        CodePalette.gutter.setFill()
        bounds.fill()
        CodePalette.gutterLine.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

        guard let textView, let scrollView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let scrollY = scrollView.contentView.bounds.origin.y
        let inset = textView.textContainerInset.height
        let visible = NSRect(x: 0, y: scrollY - inset, width: 1, height: bounds.height).insetBy(dx: 0, dy: -20)
        let glyphs = layout.glyphRange(forBoundingRect: NSRect(x: 0, y: visible.minY, width: container.size.width, height: visible.height), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = lineNumber(at: min(textView.selectedRange().location, string.length))
        let baseline = CodePalette.font.ascender - CodePalette.gutterFont.ascender

        func draw(_ number: Int, top: CGFloat) {
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: CodePalette.gutterFont,
                .foregroundColor: number == caretLine ? CodePalette.gutterCurrent : CodePalette.gutterText,
            ])
            label.draw(at: NSPoint(x: bounds.maxX - 12 - label.size().width, y: top + inset - scrollY + baseline))
        }

        if string.length == 0 {
            draw(1, top: 0)
            return
        }
        var index = characters.location
        let end = NSMaxRange(characters)
        repeat {
            let lineRange = string.lineRange(for: NSRange(location: min(index, string.length - 1), length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(lineNumber(at: lineRange.location), top: fragment.minY)
            index = NSMaxRange(lineRange)
        } while index < end
        // The empty line after a trailing newline.
        if string.character(at: string.length - 1) == 10, end >= string.length, layout.extraLineFragmentRect.height > 0 {
            draw(lineStarts.count, top: layout.extraLineFragmentRect.minY)
        }
    }
}

/// Editor colors, GitHub's light and dark code themes.
@MainActor
enum CodePalette {
    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        .dynamic(light: NSColor(hex: light, alpha: alpha), dark: NSColor(hex: dark, alpha: alpha))
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let italicFont: NSFont = {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 12) ?? font
    }()
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    static let background = dynamic(0xFFFFFF, 0x161616)
    static let gutter = dynamic(0xF8F8F8, 0x141414)
    static let gutterLine = dynamic(0x141414, 0xF0F0F0, alpha: 0.06)
    static let gutterText = dynamic(0x8C959F, 0x5A5F66)
    static let gutterCurrent = dynamic(0x1F2328, 0xE6EDF3)
    static let selection = dynamic(0x0969DA, 0x388BFD, alpha: 0.25)
    static let text = dynamic(0x1F2328, 0xE6EDF3)

    static func color(for token: SyntaxHighlighter.Token) -> NSColor {
        switch token {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number, .constant, .attribute: constant
        case .function, .decorator: function
        case .type, .property: type
        case .tag: tag
        }
    }

    private static let keyword = dynamic(0xCF222E, 0xFF7B72)
    private static let string = dynamic(0x0A3069, 0xA5D6FF)
    private static let comment = dynamic(0x6E7781, 0x8B949E)
    private static let constant = dynamic(0x0550AE, 0x79C0FF)
    private static let function = dynamic(0x8250DF, 0xD2A8FF)
    private static let type = dynamic(0x953800, 0xFFA657)
    private static let tag = dynamic(0x116329, 0x7EE787)
}

/// File-type icons for the tree and the editor tab, colored like an editor's.
enum FileIcon {
    static func symbol(for name: String, isDirectory: Bool) -> (name: String, color: Color) {
        if isDirectory { return ("folder.fill", Color(light: 0x6E7FA3, dark: 0x8FA1C7)) }
        switch CodeLanguage(fileName: name) {
        case .python: return ("chevron.left.forwardslash.chevron.right", Color(light: 0x3572A5, dark: 0x6FA8DC))
        case .xml: return ("chevron.left.slash.chevron.right", Color(light: 0xC2410C, dark: 0xF59E5B))
        case .javascript, .typescript: return ("curlybraces", Color(light: 0xA16207, dark: 0xEAB308))
        case .json: return ("curlybraces.square", Color(light: 0x6D28D9, dark: 0xB794F6))
        case .swift: return ("swift", Color(light: 0xE0592A, dark: 0xF2784B))
        case .css: return ("paintbrush", Color(light: 0x2563EB, dark: 0x60A5FA))
        case .shell: return ("terminal", Color(light: 0x15803D, dark: 0x4ADE80))
        case .yaml: return ("list.bullet.indent", Color(light: 0xBE123C, dark: 0xFB7185))
        case .sql: return ("cylinder.split.1x2", Color(light: 0x0E7490, dark: 0x22D3EE))
        case .markdown: return ("text.alignleft", Color(light: 0x0369A1, dark: 0x7DD3FC))
        case .plain:
            let ext = (name as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(ext) { return ("photo", Color(light: 0x0F766E, dark: 0x2DD4BF)) }
            if ["csv", "xlsx", "xls"].contains(ext) { return ("tablecells", Color(light: 0x15803D, dark: 0x4ADE80)) }
            if ["po", "pot"].contains(ext) { return ("globe", Color(light: 0x0369A1, dark: 0x7DD3FC)) }
            return ("doc.text", Theme.textTertiary)
        }
    }
}
