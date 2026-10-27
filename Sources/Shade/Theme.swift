import AppKit
import SwiftUI

/// Panel color themes. Dark and Light follow the standard macOS appearances; Paper is Light with a warm,
/// yellowish tint and brown text.
enum Theme: String, CaseIterable, Identifiable {
    case dark, light, paper

    var id: String { rawValue }

    var name: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .paper: return "Paper"
        }
    }

    var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }

    var material: NSVisualEffectView.Material {
        self == .dark ? .hudWindow : .popover
    }

    /// Color laid over the blur; nil for none.
    var tint: NSColor? {
        switch self {
        case .dark, .light: return nil
        case .paper: return NSColor(srgbRed: 0.98, green: 0.91, blue: 0.66, alpha: 0.8)
        }
    }

    /// Text color for notes and translations; nil uses the appearance's default.
    var textColor: Color? {
        self == .paper ? Color(red: 0.30, green: 0.22, blue: 0.10) : nil
    }

    /// Base color for code in the file and diff viewers.
    var codeTextColor: NSColor {
        self == .paper ? NSColor(srgbRed: 0.30, green: 0.22, blue: 0.10, alpha: 1) : .labelColor
    }

    /// The 16 ANSI colors for terminal cards (0–7 normal, 8–15 bright), tuned for contrast on
    /// `terminalBackground`. Bright black (8) is what most command-line tools use for hints, so it stays readable,
    /// also when dimmed. Dark follows VS Code's Dark+, Light follows GitHub's light theme, and Paper is a warm
    /// palette without colors that vanish on paper.
    var terminalPalette: [UInt32] {
        switch self {
        case .dark:
            return [0x3b3f45, 0xf14c4c, 0x23d18b, 0xe5c07b, 0x3b8eea, 0xd670d6, 0x29b8db, 0xd4d4d4,
                    0x9aa2ab, 0xff6b6b, 0x5af78e, 0xf4e07a, 0x6cb6ff, 0xe48eff, 0x56d4e8, 0xffffff]
        case .light:
            return [0x24292f, 0xcf222e, 0x116329, 0x7d4e00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                    0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f]
        case .paper:
            return [0x3a2c17, 0xb3261e, 0x5f7a00, 0x8a6100, 0x1f6fb2, 0xa8327a, 0x1c8079, 0x6e5f45,
                    0x7a6a4f, 0xc94a16, 0x6f8c00, 0x9e7200, 0x2f86cf, 0x6c5fb0, 0x23938b, 0x4d3819]
        }
    }

    /// Tells command-line tools whether the terminal is dark or light ("foreground;background" as ANSI numbers).
    var colorFGBG: String { self == .dark ? "15;0" : "0;15" }

    var terminalForeground: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1)
        case .light: return NSColor(white: 0.1, alpha: 1)
        case .paper: return NSColor(srgbRed: 0.30, green: 0.22, blue: 0.10, alpha: 1)
        }
    }

    var terminalBackground: NSColor {
        switch self {
        // Not pure black: dim text (SGR 2) is blended halfway towards the background, and on black the dim
        // hints tools like Copilot CLI show became unreadable.
        case .dark: return NSColor(srgbRed: 0.086, green: 0.094, blue: 0.11, alpha: 1)
        case .light: return .white
        case .paper: return NSColor(srgbRed: 0.99, green: 0.94, blue: 0.76, alpha: 1)
        }
    }

}

extension Settings.GroupColor {
    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .pink: return .pink
        case .purple: return .purple
        case .cyan: return .cyan
        case .orange: return .orange
        case .grey: return .gray
        }
    }
}
