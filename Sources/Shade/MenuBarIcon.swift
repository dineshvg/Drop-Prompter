import AppKit

/// Shade's menu bar symbol: a window shade with roller, slats, hem and pull ring (the "Classic Window Shade"
/// design), drawn in code so it stays sharp at every scale. It's a template image, so macOS tints it for light
/// and dark menu bars. While a command runs in a terminal card, a dot appears at the top right.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // Roller at the top.
            NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 14, height: 2), xRadius: 1, yRadius: 1).fill()
            // The shade: three slats.
            for slat in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: 3.5, y: 5.3 + CGFloat(slat) * 2.4, width: 11, height: 1.4),
                             xRadius: 0.5, yRadius: 0.5).fill()
            }
            // Hem bar and pull ring.
            NSBezierPath(roundedRect: NSRect(x: 3, y: 12.3, width: 12, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: 7.4, y: 14.3, width: 3.2, height: 3.2))
            ring.lineWidth = 1
            ring.stroke()

            if active {
                // Clear a gap around the dot so it reads as separate from the shade.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 11.5, y: 0, width: 6.5, height: 6.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 12.75, y: 1.25, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "Shade, a command is running" : "Shade"
        return image
    }
}
