import AppKit

/// Borderless, floating panel that sits above full-screen apps and on every Space.
/// It can take keyboard focus without activating the app, so the meeting app stays frontmost.
final class ShadePanel: NSPanel {
    /// Factory instead of a custom init, so the inherited NSWindow initializers stay intact.
    static func make() -> ShadePanel {
        let panel = ShadePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.configure()
        return panel
    }

    private func configure() {
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua) // replaced by the theme once settings are applied
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Allow the off-screen "hidden" frame above the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// An accessory app has no visible Edit menu, so route the standard shortcuts explicitly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        let action: Selector?
        switch (key, flags == .command) {
        case ("x", true): action = #selector(NSText.cut(_:))
        case ("c", true): action = #selector(NSText.copy(_:))
        case ("v", true): action = #selector(NSText.paste(_:))
        case ("a", true): action = #selector(NSText.selectAll(_:))
        case ("z", true): action = Selector(("undo:"))
        case ("z", false): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Mask with square top corners and rounded bottom corners, for the visual effect view.
func bottomRoundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSRect(x: 0, y: radius, width: edge, height: edge - radius).fill()
        return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
}
