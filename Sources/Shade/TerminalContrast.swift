import AppKit

/// Keeps text readable on the card's background, like iTerm2's "Minimum contrast". Tools such as Copilot CLI
/// draw hints in dim text or in fixed 256-color and RGB greys, which can end up almost the color of the
/// background, all the more on a see-through panel. This resolves every text color in the program's output,
/// draws dim text itself, and replaces colors that are too close to the background. Text on a background
/// the program chose itself is left as it is.
struct TerminalContrast {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// WCAG contrast ratio text needs against the background; 4.5 is the WCAG AA level for body text.
    static let minimumRatio = 4.5
    /// Dim text stays recognizably fainter, but readable.
    static let minimumDimRatio = 3.0
    /// How far dim text is blended towards the background before the minimum applies.
    static let dimAmount = 0.4

    private var background: RGB = (0, 0, 0)
    private var foreground: RGB = (1, 1, 1)
    private var palette: [RGB] = []

    // SGR state of the output so far.
    private var foregroundColor: Attribute = .standard
    private var hasOwnBackground = false
    private var isInverse = false
    private var isBold = false
    private var isDim = false
    /// Whether the text color currently set in the terminal is one of ours.
    private var overriding = false
    /// The start of an escape sequence that the previous chunk of output ended in.
    private var pending: [UInt8] = []

    private enum Attribute: Equatable {
        case standard
        case palette(Int)
        case rgb(Double, Double, Double)
    }

    init(theme: Theme, backgroundOpacity: Double) {
        setColors(theme: theme, backgroundOpacity: backgroundOpacity)
    }

    /// The panel is see-through, so the background text is read against is the theme's background partly
    /// mixed with whatever is behind it. A mid grey stands in for that.
    mutating func setColors(theme: Theme, backgroundOpacity: Double) {
        let opacity = min(max(backgroundOpacity, 0), 1)
        background = Self.mix(Self.rgb(theme.terminalBackground), (0.5, 0.5, 0.5), 1 - opacity)
        foreground = Self.rgb(theme.terminalForeground)
        palette = theme.terminalPalette.map { value -> RGB in
            (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
        }
    }

    /// The output with dim and low-contrast text colors replaced.
    mutating func filter(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        let input = pending + slice
        pending = []
        var output: [UInt8] = []
        output.reserveCapacity(input.count + 16)
        var i = 0
        while i < input.count {
            guard input[i] == 0x1b else {
                output.append(input[i])
                i += 1
                continue
            }
            guard i + 1 < input.count else {
                pending = Array(input[i...])
                break
            }
            guard input[i + 1] == UInt8(ascii: "[") else {
                output.append(input[i])
                i += 1
                continue
            }
            // CSI: parameter and intermediate bytes, then one final byte.
            var end = i + 2
            while end < input.count, (0x20...0x3f).contains(input[end]) { end += 1 }
            guard end < input.count else {
                // Wait for the rest, unless this isn't a real sequence.
                if input.count - i < 256 { pending = Array(input[i...]) } else { output.append(contentsOf: input[i...]) }
                break
            }
            output.append(contentsOf: input[i...end])
            if input[end] == UInt8(ascii: "m") {
                output.append(contentsOf: graphicRendition(Array(input[(i + 2)..<end])))
            }
            i = end + 1
        }
        return output
    }

    /// Tracks one SGR sequence and returns what to send after it so the text color stays readable.
    private mutating func graphicRendition(_ parameterBytes: [UInt8]) -> [UInt8] {
        // Colon sub-parameters (38:2::r:g:b) are rare; leave those sequences alone.
        guard !parameterBytes.contains(UInt8(ascii: ":")) else { return [] }
        let text = String(decoding: parameterBytes, as: UTF8.self)
        let parameters = text.isEmpty ? [0] : text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            switch parameter {
            case 0:
                foregroundColor = .standard
                hasOwnBackground = false
                isInverse = false
                isBold = false
                isDim = false
            case 1: isBold = true
            case 2: isDim = true
            case 22:
                isBold = false
                isDim = false
            case 7: isInverse = true
            case 27: isInverse = false
            case 30...37: foregroundColor = .palette(parameter - 30)
            case 90...97: foregroundColor = .palette(parameter - 90 + 8)
            case 39: foregroundColor = .standard
            case 40...47, 100...107: hasOwnBackground = true
            case 49: hasOwnBackground = false
            case 38, 48:
                let (color, used) = Self.extendedColor(parameters, at: index + 1)
                index += used
                if parameter == 38 {
                    if let color { foregroundColor = color }
                } else {
                    hasOwnBackground = true
                }
            default: break
            }
            index += 1
        }

        guard !hasOwnBackground, !isInverse, let color = readableColor() else {
            guard overriding else { return [] }
            // Hand the program's own color and dimming back to the terminal.
            overriding = false
            return Array("\u{1b}[\(sgr(for: foregroundColor))\(isDim ? ";2" : "")m".utf8)
        }
        overriding = true
        let r = Int((color.r * 255).rounded()), g = Int((color.g * 255).rounded()), b = Int((color.b * 255).rounded())
        // 22 ends the terminal's own dimming (and bold, which comes back if it was on).
        return Array("\u{1b}[22\(isBold ? ";1" : "");38;2;\(r);\(g);\(b)m".utf8)
    }

    /// The text color to draw instead of the program's, or nil when the program's is fine as it is.
    private func readableColor() -> RGB? {
        var color: RGB
        switch foregroundColor {
        case .standard:
            guard isDim else { return nil }
            color = foreground
        case .palette(let index):
            // Like the terminal, bold makes the first eight colors bright.
            let shown = isBold && index < 8 ? index + 8 : index
            guard shown < palette.count else { return nil }
            color = palette[shown]
        case .rgb(let r, let g, let b):
            color = (r, g, b)
        }
        let original = color
        if isDim { color = Self.mix(color, background, Self.dimAmount) }
        color = withContrast(color, isDim ? Self.minimumDimRatio : Self.minimumRatio)
        if !isDim, color == original, case .palette = foregroundColor { return nil }
        return color
    }

    /// `color` blended towards the card's foreground just enough to reach `minimum` contrast.
    private func withContrast(_ color: RGB, _ minimum: Double) -> RGB {
        let backgroundLuminance = Self.luminance(background)
        guard Self.ratio(Self.luminance(color), backgroundLuminance) < minimum else { return color }
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if Self.ratio(Self.luminance(Self.mix(color, foreground, middle)), backgroundLuminance) < minimum {
                low = middle
            } else {
                high = middle
            }
        }
        return Self.mix(color, foreground, high)
    }

    private func sgr(for attribute: Attribute) -> String {
        switch attribute {
        case .standard: return "39"
        case .palette(let index): return index < 8 ? "\(30 + index)" : "\(90 + index - 8)"
        case .rgb(let r, let g, let b):
            return "38;2;\(Int((r * 255).rounded()));\(Int((g * 255).rounded()));\(Int((b * 255).rounded()))"
        }
    }

    // MARK: - Colors

    /// The color of `38;5;n` or `38;2;r;g;b` starting at `start` (after the 38/48), and how many
    /// parameters it used.
    private static func extendedColor(_ parameters: [Int], at start: Int) -> (Attribute?, Int) {
        guard start < parameters.count else { return (nil, 0) }
        switch parameters[start] {
        case 5:
            guard start + 1 < parameters.count else { return (nil, 1) }
            return (xterm256(parameters[start + 1]), 2)
        case 2:
            guard start + 3 < parameters.count else { return (nil, parameters.count - start) }
            let channel = { (value: Int) in Double(min(max(value, 0), 255)) / 255 }
            return (.rgb(channel(parameters[start + 1]), channel(parameters[start + 2]), channel(parameters[start + 3])), 4)
        default:
            return (nil, 0)
        }
    }

    /// The 16 palette colors, then the standard xterm values of the 256-color cube and grey ramp.
    private static func xterm256(_ index: Int) -> Attribute? {
        switch index {
        case 0...15:
            return .palette(index)
        case 16...231:
            let levels = [0.0, 95, 135, 175, 215, 255]
            let n = index - 16
            return .rgb(levels[n / 36] / 255, levels[(n / 6) % 6] / 255, levels[n % 6] / 255)
        case 232...255:
            let grey = Double(8 + (index - 232) * 10) / 255
            return .rgb(grey, grey, grey)
        default:
            return nil
        }
    }

    private static func rgb(_ color: NSColor) -> RGB {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    private static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        (a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
    }

    private static func luminance(_ color: RGB) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    }

    private static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
