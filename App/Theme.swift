import MountagentDeskKit
import AppKit
import SwiftUI

/// Design tokens, modelled on Cursor's own design system (Cursor 3.25 theme + Agents
/// window CSS): one ink color per appearance, with every text, fill and stroke level
/// expressed as that ink at a fixed opacity. Every color resolves per appearance, so
/// views never branch on light/dark.
enum Theme {
    /// The raw values, for AppKit views (text, code, terminal) that need NSColor.
    enum Hex {
        /// The ink every level derives from.
        static let inkLight: UInt32 = 0x141414
        static let inkDark: UInt32 = 0xF0F0F0
        static let backgroundLight: UInt32 = 0xFCFCFC
        static let backgroundDark: UInt32 = 0x181818
        /// Sidebar, chrome, code blocks and terminals.
        static let sidebarLight: UInt32 = 0xF3F3F3
        static let sidebarDark: UInt32 = 0x141414
        static let accentLight: UInt32 = 0x2778C1
        static let accentDark: UInt32 = 0x81A1C1
    }

    /// The ink at an opacity: every text, fill and stroke level is one of these.
    static func ink(_ opacity: CGFloat) -> Color {
        Color(nsColor: inkColor(opacity))
    }

    static func inkColor(_ opacity: CGFloat) -> NSColor {
        .dynamic(light: NSColor(hex: Hex.inkLight, alpha: opacity), dark: NSColor(hex: Hex.inkDark, alpha: opacity))
    }

    // Surfaces (opaque)
    static let background = Color(light: Hex.backgroundLight, dark: Hex.backgroundDark)   // conversation
    static let sidebar = Color(light: Hex.sidebarLight, dark: Hex.sidebarDark)            // sidebar and chrome
    static let elevated = Color(light: 0xFFFFFF, dark: 0x1F1F1F)     // composer, cards
    static let surface = Color(light: 0xF6F6F6, dark: 0x1D1D1D)      // expanded tool output
    static let codeBackground = Color(light: Hex.sidebarLight, dark: Hex.sidebarDark)

    // Fills and strokes (ink at Cursor's levels)
    static let userFill = ink(0.04)
    static let selected = ink(0.08)       // --cursor-bg-tertiary
    static let hover = ink(0.06)          // --cursor-bg-quaternary
    static let hairline = ink(0.08)
    static let stroke = ink(0.14)         // --cursor-stroke-secondary

    // Text
    static let textPrimary = ink(0.92)
    static let textSecondary = ink(0.55)
    static let textTertiary = ink(0.37)

    // Accent and status (Cursor theme values)
    static let accent = Color(light: Hex.accentLight, dark: Hex.accentDark)
    static let success = Color(light: 0x007041, dark: 0x70B489)
    static let warning = Color(light: 0xCD4500, dark: 0xF1B467)
    static let danger = Color(light: 0xBE1744, dark: 0xE34671)

    /// Usage and quota levels: green while there is plenty left, amber past half, red near the cap.
    static func level(percent: Int) -> Color {
        percent >= 80 ? danger : percent >= 50 ? warning : success
    }

    /// Identity hues for projects and people: distinct from one another and readable on
    /// both surfaces. `hue(for:)` picks one by a stable hash, so a name keeps its color.
    static let identityHues: [Color] = [
        Color(light: 0x2F6FDE, dark: 0x6EA8FE),   // blue
        Color(light: 0x0F8A5F, dark: 0x4CC38A),   // green
        Color(light: 0xB25E09, dark: 0xF0A04B),   // orange
        Color(light: 0x8B3FD9, dark: 0xB58CFF),   // violet
        Color(light: 0xC2255C, dark: 0xF06595),   // pink
        Color(light: 0x0B7F8F, dark: 0x3BC9DB),   // teal
        Color(light: 0x9C7A00, dark: 0xE6C34A),   // gold
        Color(light: 0x4C5FD5, dark: 0x91A7FF),   // indigo
    ]

    static func hue(for key: String) -> Color {
        // FNV-1a: `hashValue` is seeded per launch and would reshuffle colors.
        var hash: UInt32 = 2_166_136_261
        for byte in key.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return identityHues[Int(hash % UInt32(identityHues.count))]
    }

    /// Tool kinds in the transcript, so a run of steps reads at a glance.
    enum Tool {
        static let shell = Color(light: 0x0F8A5F, dark: 0x4CC38A)
        static let edit = Color(light: 0x2F6FDE, dark: 0x6EA8FE)
        static let search = Color(light: 0x8B3FD9, dark: 0xB58CFF)
        static let web = Color(light: 0x0B7F8F, dark: 0x3BC9DB)
        static let agent = Color(light: 0xB25E09, dark: 0xF0A04B)
    }

    /// Call-to-action fill (Pull, Push, Publish), GitHub Desktop's blue.
    static let action = Color(light: 0x1F6FEB, dark: 0x2F81F7)

    // Agents: only for small identity marks.
    static let claude = Color(light: 0xC15F3C, dark: 0xD97757)
    static let cursor = Color(light: 0x5A6B8C, dark: 0x9AA8C7)
    static let codex = Color(light: 0x0E8A6A, dark: 0x3CC79F)
    static let antigravity = Color(light: 0x6B4FD8, dark: 0xA28BFF)

    // Layout
    static let columnWidth: CGFloat = 760
    static let chromeHeight: CGFloat = 40
    static let turnSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 10

    enum Radius {
        static let chip: CGFloat = 4
        static let row: CGFloat = 6
        static let codeBlock: CGFloat = 6
        static let card: CGFloat = 8
        static let bubble: CGFloat = 8
        static let composer: CGFloat = 10
    }

    enum Font {
        static let body = SwiftUI.Font.system(size: 14)
        static let bodyLineSpacing: CGFloat = 5          // 14pt on a ~22pt line
        static let code = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let toolLabel = SwiftUI.Font.system(size: 13)
        static let toolTarget = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let ui = SwiftUI.Font.system(size: 12)    // sidebar rows, controls
        static let uiMedium = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
        static let chip = SwiftUI.Font.system(size: 12)
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: .dynamic(light: light, dark: dark))
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    /// A color that follows the light or dark appearance it is drawn in.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Project {
    /// The project's identity color: sidebar group, selected session, branch chip.
    var tint: Color { Theme.hue(for: name) }
}

extension AgentKind {
    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "hexagon"
        case .antigravity: "atom"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Theme.claude
        case .cursor: Theme.cursor
        case .codex: Theme.codex
        case .antigravity: Theme.antigravity
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

/// The System / Light / Dark setting. Applied through `NSApp.appearance`, which reaches
/// every window, sheet, menu and the dynamic colors above (`.preferredColorScheme` would
/// only cover one window and sticks when switched back to System).
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    static var current: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Shared modifiers

extension View {
    /// A menu drawn by its own label: no button chrome, no arrow, as small as its label.
    func chipMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// Fills on hover, for rows and borderless buttons.
    func hoverHighlight(cornerRadius: CGFloat = Theme.Radius.row) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }

    /// A raised surface (composer, pills): opaque elevated fill and a 1px stroke, no blur,
    /// as Cursor draws its prompt box.
    func floatingSurface(cornerRadius: CGFloat) -> some View {
        background(Theme.elevated, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// A compact dropdown control (composer chips, toolbar menus): text only until hovered.
struct ChipLabel: View {
    let title: String
    var symbol: String?
    var tint: Color?
    /// Narrow panes: only the icon when there is one, else a shortened title.
    @Environment(\.compactChips) private var compact

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tint ?? Theme.textSecondary)
            }
            if !compact || symbol == nil {
                Text(title)
                    .foregroundStyle(Theme.textSecondary)
                    .truncationMode(.tail)
                    .frame(maxWidth: compact ? 64 : nil)
            }
            if !compact {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .help(compact ? title : "")
        .font(Theme.Font.chip)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 22)
        .hoverHighlight(cornerRadius: Theme.Radius.chip)
    }
}

/// A 24pt icon button for chrome bars, Cursor style: secondary icon, fill on hover.
struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .hoverHighlight(cornerRadius: Theme.Radius.chip)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Lets the window be dragged by a custom title bar (the system one is hidden).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Date {
    /// "now", "5m", "3h", "2d", then a short date: for tight places such as the sidebar.
    var shortAge: String {
        relativeAge.map { $0.isEmpty ? "now" : $0 } ?? formatted(.dateTime.day().month(.abbreviated))
    }

    /// "just now", "5m ago", "3h ago", "2d ago", then a short date.
    var age: String {
        relativeAge.map { $0.isEmpty ? "just now" : $0 + " ago" } ?? formatted(.dateTime.day().month(.abbreviated))
    }

    /// "" under a minute, "5m", "3h" or "2d" within a week, nil after.
    private var relativeAge: String? {
        let seconds = Date().timeIntervalSince(self)
        switch seconds {
        case ..<60: return ""
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default: return nil
        }
    }
}
