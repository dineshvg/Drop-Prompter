import AppKit

/// Resize grip drawn and handled in AppKit. SwiftUI drag gestures did not get the drags reliably
/// in the non-activating panel; a plain NSView with acceptsFirstMouse does.
final class ResizeHandleView: NSView {
    enum Kind { case bottom, corner }

    private let kind: Kind
    var onBegin: () -> Void = {}
    var onDrag: (_ includeWidth: Bool) -> Void = { _ in }
    var onEnd: () -> Void = {}

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var cursor: NSCursor { kind == .bottom ? .resizeUpDown : .crosshair }

    // Cursor rects only apply while the app is active; the panel usually isn't, so use a tracking area.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) { onBegin() }
    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        onDrag(kind == .corner)
    }
    override func mouseUp(with event: NSEvent) { onEnd() }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .bottom:
            NSColor.white.withAlphaComponent(0.35).setFill()
            let grip = NSRect(x: bounds.midX - 22, y: bounds.midY - 2.5, width: 44, height: 5)
            NSBezierPath(roundedRect: grip, xRadius: 2.5, yRadius: 2.5).fill()
        case .corner:
            NSColor.white.withAlphaComponent(0.45).setStroke()
            for offset in stride(from: CGFloat(4), through: 12, by: 4) {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: bounds.maxX - offset - 4, y: 4))
                line.line(to: NSPoint(x: bounds.maxX - 4, y: offset + 4))
                line.lineWidth = 1.5
                line.stroke()
            }
        }
    }
}
