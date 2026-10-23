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
        static let backgroundBlack: UInt32 = 0x181818
        static let backgroundDim: UInt32 = 0x2A2B2F
        /// Sidebar, chrome, code blocks and terminals.
        static let sidebarLight: UInt32 = 0xF3F3F3
        static let sidebarBlack: UInt32 = 0x141414
        static let sidebarDim: UInt32 = 0x232428

        /// The dark surfaces of the current shade (Dark or Dim).
        static var backgroundDark: UInt32 { darkShade == .dim ? backgroundDim : backgroundBlack }
        static var sidebarDark: UInt32 { darkShade == .dim ? sidebarDim : sidebarBlack }
        static let accentLight: UInt32 = 0x2778C1
        static let accentDark: UInt32 = 0x81A1C1
    }

    /// How deep the dark appearance's surfaces are: Dark's near-black or Dim's grey.
    enum DarkShade { case black, dim }

    /// Read whenever a surface color is drawn; `Appearance.apply()` sets it.
    nonisolated(unsafe) static var darkShade: DarkShade = Appearance.current == .dim ? .dim : .black

    /// The ink at an opacity: every text, fill and stroke level is one of these.
    static func ink(_ opacity: CGFloat) -> Color {
        Color(nsColor: inkColor(opacity))
    }

    static func inkColor(_ opacity: CGFloat) -> NSColor {
        .dynamic(light: NSColor(hex: Hex.inkLight, alpha: opacity), dark: NSColor(hex: Hex.inkDark, alpha: opacity))
    }

    // Surfaces (opaque)
    static let background = Color(nsColor: .surface(light: Hex.backgroundLight, dark: Hex.backgroundBlack, dim: Hex.backgroundDim))   // conversation
    static let sidebar = Color(nsColor: .surface(light: Hex.sidebarLight, dark: Hex.sidebarBlack, dim: Hex.sidebarDim))               // sidebar and chrome
    static let elevated = Color(nsColor: .surface(light: 0xFFFFFF, dark: 0x1F1F1F, dim: 0x333439))     // composer, cards
    static let surface = Color(nsColor: .surface(light: 0xF6F6F6, dark: 0x1D1D1D, dim: 0x2F3035))      // expanded tool output
    static let codeBackground = Color(nsColor: .surface(light: Hex.sidebarLight, dark: Hex.sidebarBlack, dim: Hex.sidebarDim))

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
    static let copilot = Color(light: 0xBF3989, dark: 0xDB61A2)
    static let gemini = Color(light: 0x1A73E8, dark: 0x6EA8FE)
    static let opencode = Color(light: 0x8A6A12, dark: 0xE0B341)

    // Layout
    /// Frame interval of the "working" animations: 30 fps looks the same as the display's
    /// 120 and costs a quarter of the redraws while agents run.
    static let animationInterval: Double = 1.0 / 30
    static let columnWidth: CGFloat = 760

    /// The chat column's width limit, padding included: none with Full-Width Chat on.
    static func chatMaxWidth(fullWidth: Bool) -> CGFloat {
        fullWidth ? .infinity : columnWidth + 48
    }
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

    /// A surface: light, or dark in the current shade (Dark's near-black or Dim's grey).
    static func surface(light: UInt32, dark: UInt32, dim: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return NSColor(hex: light) }
            return NSColor(hex: Theme.darkShade == .dim ? dim : dark)
        }
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

extension ServerEnvironment {
    /// Red for live, amber for UAT, green for test: the same signal everywhere a server shows.
    var tint: Color {
        switch self {
        case .live: Theme.danger
        case .uat: Theme.warning
        case .test: Theme.success
        case .dev: Theme.accent
        }
    }

}

extension Image {
    /// An SF Symbol, or one of the app's own symbols (Copilot's mark) from the asset catalog.
    init(symbol name: String) {
        self = Image.customSymbols.contains(name) ? Image(name) : Image(systemName: name)
    }

    static let customSymbols: Set<String> = ["copilot"]
}

extension AgentKind {
    /// An SF Symbol name, or a custom symbol's asset name; draw it with `Image(symbol:)`.
    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "hexagon"
        case .antigravity: "atom"
        case .copilot: "copilot"
        case .gemini: "sparkles"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .claude: Theme.claude
        case .cursor: Theme.cursor
        case .codex: Theme.codex
        case .antigravity: Theme.antigravity
        case .copilot: Theme.copilot
        case .gemini: Theme.gemini
        case .opencode: Theme.opencode
        }
    }

    var shortName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
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
    /// Dark, with grey surfaces instead of near-black ones.
    case dim

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .dim: "Dim"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        case .dim: "moon.haze"
        }
    }

    static var current: Appearance {
        UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system
    }

    @MainActor
    func apply() {
        let shade: Theme.DarkShade = self == .dim ? .dim : .black
        let shadeChanged = Theme.darkShade != shade
        Theme.darkShade = shade
        let target: NSAppearance? = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .dim: NSAppearance(named: .darkAqua)
        }
        // Dark and Dim are the same NSAppearance, so nothing would redraw; passing through
        // light makes every surface color resolve again.
        if shadeChanged, NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSApp.appearance = NSAppearance(named: .aqua)
            DispatchQueue.main.async { NSApp.appearance = target }
        } else {
            NSApp.appearance = target
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
                Image(symbol: symbol)
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
/// Color schemes for the terminals (Terminal panel, server tabs, setup sheet), picked in
/// Settings → Appearance. Mountagent follows the app's light or dark look; the others are
/// always dark, as in Termius.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case app, hackerBlue, dracula, solarized

    static let key = "terminalTheme"
    var id: String { rawValue }

    static var current: TerminalTheme {
        UserDefaults.standard.string(forKey: key).flatMap(TerminalTheme.init(rawValue:)) ?? .app
    }

    var title: String {
        switch self {
        case .app: "Mountagent"
        case .hackerBlue: "Hacker Blue"
        case .dracula: "Dracula"
        case .solarized: "Solarized Dark"
        }
    }

    struct Scheme: Equatable {
        let background: UInt32
        let foreground: UInt32
        let cursor: UInt32
        /// Black, red, green, yellow, blue, magenta, cyan, white, then their bright forms.
        let ansi: [UInt32]
    }

    func scheme(dark: Bool) -> Scheme {
        switch self {
        case .app where dark:
            Scheme(background: Theme.Hex.sidebarDark, foreground: 0xDCDFE4, cursor: Theme.Hex.inkDark, ansi: [
                0x3F4451, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xD7DAE0,
                0x5C6370, 0xFF7A85, 0xB5E890, 0xFFD68A, 0x7CC4FF, 0xDA8EF0, 0x6FD3DF, 0xFFFFFF,
            ])
        case .app:
            Scheme(background: Theme.Hex.sidebarLight, foreground: 0x2B2D33, cursor: Theme.Hex.inkLight, ansi: [
                0x383A42, 0xD8453A, 0x3F8F3E, 0xB27A00, 0x3A6FE0, 0xA02BA0, 0x0A80AE, 0x9A9BA2,
                0x696C77, 0xEE5D52, 0x4FA94E, 0xC98C00, 0x5585F0, 0xB73EB5, 0x1493C6, 0x55565C,
            ])
        case .hackerBlue:
            Scheme(background: 0x0E1726, foreground: 0xD6E2F0, cursor: 0x3BA0FF, ansi: [
                0x1C2738, 0xFF5370, 0x3DD68C, 0xFFCB6B, 0x3BA0FF, 0xC792EA, 0x2BD4E0, 0xC8D3E0,
                0x4A5A73, 0xFF7A90, 0x6EF0A8, 0xFFDD8F, 0x6CB8FF, 0xDDB0F5, 0x6BE6EE, 0xFFFFFF,
            ])
        case .dracula:
            Scheme(background: 0x282A36, foreground: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ])
        case .solarized:
            Scheme(background: 0x002B36, foreground: 0x93A1A1, cursor: 0x93A1A1, ansi: [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                0x657B83, 0xFF6E64, 0xA6BD00, 0xD7AD00, 0x5DB0F0, 0xF0629D, 0x46C9B8, 0xFDF6E3,
            ])
        }
    }

    /// The terminal's background, for the area around it.
    func background(dark: Bool) -> Color {
        Color(nsColor: NSColor(hex: scheme(dark: dark).background))
    }
}

/// A colored rounded square with a white glyph, as System Settings marks its panes.
struct TintedIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

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

extension ChatSession {
    /// The agent's mark, or a terminal agent's, or a terminal for a terminal session.
    var symbolName: String {
        guard let command else { return agent.symbolName }
        return TerminalCommands.agent(for: command)?.symbolName ?? "terminal"
    }

    var tint: Color {
        guard let command else { return agent.tint }
        return TerminalCommands.agent(for: command)?.tint ?? Theme.textSecondary
    }
}

extension TerminalAgent {
    var symbolName: String {
        switch name {
        case "Kiro": "k.circle.fill"
        case "Amp": "a.circle.fill"
        case "Kimi Code": "moon.stars.fill"
        case "Grok Build": "x.circle.fill"
        case "Mistral Vibe": "wind"
        case "Droid": "f.circle.fill"
        default: "terminal"
        }
    }

    var tint: Color {
        switch name {
        case "Kiro": Color(light: 0x7A3EE6, dark: 0xA87BFF)
        case "Amp": Color(light: 0xD8452F, dark: 0xF06A52)
        case "Kimi Code": Color(light: 0x1769E0, dark: 0x5C9DFF)
        case "Grok Build": Theme.textPrimary
        case "Mistral Vibe": Color(light: 0xE0560B, dark: 0xFF8A3D)
        case "Droid": Color(light: 0xB4690E, dark: 0xE8A33D)
        default: Theme.textSecondary
        }
    }

    var isInstalled: Bool { ExecutableLocator.find(executable) != nil }
}
