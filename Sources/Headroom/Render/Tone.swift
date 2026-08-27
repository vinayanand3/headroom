import AppKit

/// The semantic ramp. Deliberately independent of the app's chrome accent —
/// hue is the only part of the gauge readable from the corner of the eye, so
/// nothing else is allowed to compete with it.
struct Tone {
    let dark: NSColor
    let light: NSColor

    static func forUsage(_ percent: Double) -> Tone {
        switch percent {
        case ..<60:
            return Tone(dark: NSColor(srgbRed: 0.07, green: 0.66, blue: 0.41, alpha: 1),
                        light: NSColor(srgbRed: 0.29, green: 0.89, blue: 0.61, alpha: 1))
        case ..<85:
            return Tone(dark: NSColor(srgbRed: 0.82, green: 0.54, blue: 0.09, alpha: 1),
                        light: NSColor(srgbRed: 1.00, green: 0.83, blue: 0.48, alpha: 1))
        default:
            return Tone(dark: NSColor(srgbRed: 0.85, green: 0.22, blue: 0.17, alpha: 1),
                        light: NSColor(srgbRed: 1.00, green: 0.58, blue: 0.52, alpha: 1))
        }
    }

    var gradient: NSGradient? { NSGradient(starting: dark, ending: light) }
}
