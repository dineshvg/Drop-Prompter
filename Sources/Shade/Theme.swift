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

    var terminalForeground: NSColor {
        switch self {
        case .dark: return .white
        case .light: return NSColor(white: 0.1, alpha: 1)
        case .paper: return NSColor(srgbRed: 0.30, green: 0.22, blue: 0.10, alpha: 1)
        }
    }

    var terminalBackground: NSColor {
        switch self {
        case .dark: return .black
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
