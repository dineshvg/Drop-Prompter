import AppKit

/// Keeps text readable on the card's background, like iTerm2's "Minimum contrast". Tools such as Copilot CLI
/// draw hints in fixed 256-color or RGB greys that the 16-color palette doesn't reach, so this rewrites the
/// foreground colors in the program's output (SGR `38;5;n` and `38;2;r;g;b`) that are too close to the
/// background. Text on a background the program chose itself is left as it is.
struct TerminalContrast {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// WCAG contrast ratio text needs against the card's background; 4.5 is the WCAG AA level for body text.
    static let minimumRatio = 4.5

    var background: RGB
    var foreground: RGB

    // SGR state of the output so far.
    private var foregroundColor: RGB?
    private var hasOwnBackground = false
    private var isInverse = false
    /// Whether the last foreground color sent on was a replaced one.
    private var replaced = false
    /// The start of an escape sequence that the previous chunk of output ended in.
    private var pending: [UInt8] = []

    init(background: NSColor, foreground: NSColor) {
        self.background = Self.rgb(background)
        self.foreground = Self.rgb(foreground)
    }

    mutating func setColors(background: NSColor, foreground: NSColor) {
        self.background = Self.rgb(background)
        self.foreground = Self.rgb(foreground)
    }

    /// The output with low-contrast foreground colors replaced.
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
            let sequence = input[i...end]
            output.append(contentsOf: sequence)
            if input[end] == UInt8(ascii: "m") {
                output.append(contentsOf: graphicRendition(Array(input[(i + 2)..<end])))
            }
            i = end + 1
        }
        return output
    }

    /// Tracks one SGR sequence and returns the foreground color to send after it, if it must change.
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
                foregroundColor = nil
                hasOwnBackground = false
                isInverse = false
                replaced = false
            case 7: isInverse = true
            case 27: isInverse = false
            case 30...37, 39, 90...97:
                foregroundColor = nil
                replaced = false
            case 40...47, 100...107: hasOwnBackground = true
            case 49: hasOwnBackground = false
            case 38, 48:
                let (color, used) = Self.extendedColor(parameters, at: index + 1)
                index += used
                if parameter == 38 {
                    foregroundColor = color
                    replaced = false
                } else {
                    hasOwnBackground = true
                }
            default: break
            }
            index += 1
        }

        guard let color = foregroundColor else { return [] }
        let readable = hasOwnBackground || isInverse ? color : readableColor(color)
        let changes = readable != color
        guard changes || replaced else { return [] }
        replaced = changes
        let r = Int((readable.r * 255).rounded()), g = Int((readable.g * 255).rounded()), b = Int((readable.b * 255).rounded())
        return Array("\u{1b}[38;2;\(r);\(g);\(b)m".utf8)
    }

    /// `color` blended towards the card's foreground just enough to reach the minimum contrast.
    func readableColor(_ color: RGB) -> RGB {
        let backgroundLuminance = Self.luminance(background)
        guard Self.ratio(Self.luminance(color), backgroundLuminance) < Self.minimumRatio else { return color }
        var low = 0.0, high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if Self.ratio(Self.luminance(Self.mix(color, foreground, middle)), backgroundLuminance) < Self.minimumRatio {
                low = middle
            } else {
                high = middle
            }
        }
        return Self.mix(color, foreground, high)
    }

    // MARK: - Colors

    /// The color of `38;5;n` or `38;2;r;g;b` starting at `start` (after the 38/48), and how many
    /// parameters it used. Nil for the 16 palette colors, which the theme's palette already covers.
    private static func extendedColor(_ parameters: [Int], at start: Int) -> (RGB?, Int) {
        guard start < parameters.count else { return (nil, 0) }
        switch parameters[start] {
        case 5:
            guard start + 1 < parameters.count else { return (nil, 1) }
            return (xterm256(parameters[start + 1]), 2)
        case 2:
            guard start + 3 < parameters.count else { return (nil, parameters.count - start) }
            let channel = { (value: Int) in Double(min(max(value, 0), 255)) / 255 }
            let color: RGB = (channel(parameters[start + 1]), channel(parameters[start + 2]), channel(parameters[start + 3]))
            return (color, 4)
        default:
            return (nil, 0)
        }
    }

    /// Standard xterm values of the 256-color cube and grey ramp.
    private static func xterm256(_ index: Int) -> RGB? {
        switch index {
        case 16...231:
            let levels = [0.0, 95, 135, 175, 215, 255]
            let n = index - 16
            let color: RGB = (levels[n / 36] / 255, levels[(n / 6) % 6] / 255, levels[n % 6] / 255)
            return color
        case 232...255:
            let grey = Double(8 + (index - 232) * 10) / 255
            let color: RGB = (grey, grey, grey)
            return color
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
