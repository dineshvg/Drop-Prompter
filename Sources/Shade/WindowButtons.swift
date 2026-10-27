import SwiftUI

/// Close, roll up and maximize, drawn like the macOS window buttons. The panel is borderless, so it has no
/// title bar of its own to show the system ones in.
struct WindowButtons: View {
    let isRolledUp: Bool
    let isMaximized: Bool
    let onClose: () -> Void
    let onRollUp: () -> Void
    let onMaximize: () -> Void

    /// Like the system buttons, all three show their symbols while the pointer is over any of them.
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            button(color: Color(red: 1.00, green: 0.37, blue: 0.34), symbol: "xmark",
                   help: "Hide (Esc / ⌃Space)", action: onClose)
            button(color: Color(red: 1.00, green: 0.74, blue: 0.18), symbol: isRolledUp ? "chevron.down" : "minus",
                   help: isRolledUp ? "Roll down" : "Roll up to the toolbar", action: onRollUp)
            button(color: Color(red: 0.16, green: 0.78, blue: 0.25),
                   symbol: isMaximized && !isRolledUp ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   help: isRolledUp ? "Roll down" : isMaximized ? "Restore size" : "Fill the screen", action: onMaximize)
        }
        .onHover { isHovering = $0 }
    }

    private func button(color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.6))
                        .opacity(isHovering ? 1 : 0)
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
