import AppKit
import QuartzCore

/// Wave Meniscus, per the motion study — now stacked, one row per agent.
///
/// The insight that makes multi-agent work in a crowded menu bar: the strip is
/// only ~50pt *wide* beside the notch, but it's 32pt *tall*. Stacking thin
/// capsules costs no horizontal space at all, so three agents fit in the same
/// footprint as one. Colour carries the state; row order carries the identity.
///
/// The performance argument lives in `tick()`: wave amplitude is derived from
/// each row's spring velocity, so a row sloshes while its number is moving and
/// goes glassy-still the instant it settles. When every row has settled we stop
/// the display link entirely — idle is a static frame, not a slow animation.
final class DrainView: NSView {

    struct Row {
        let provider: ProviderID
        let reading: Reading
        let label: String
    }

    private struct RowState {
        var level: CGFloat = 0
        var target: CGFloat = 0
        var velocity: CGFloat = 0
        var phase: CGFloat = 0
        var settled: Bool { abs(target - level) < 0.0008 && abs(velocity) < 0.0008 }
    }

    private var states: [ProviderID: RowState] = [:]
    private var link: CADisplayLink?

    var rows: [Row] = [] { didSet { applyRows() } }

    /// Dropped when the clear strip is too narrow for both. A colour-coded
    /// capsule still reads at a glance; the number moves to the tooltip and menu.
    var showsLabel: Bool = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    private let labelWidth: CGFloat = 52
    private let hPad: CGFloat = 2
    private let rowGap: CGFloat = 3

    /// Thinner as agents are added, so the stack always fits the 32pt bar.
    private func rowHeight(for count: Int) -> CGFloat {
        switch count {
        case 0, 1: return 11
        case 2:    return 8
        case 3:    return 6
        default:   return 5
        }
    }

    // MARK: - State

    private func applyRows() {
        var next: [ProviderID: RowState] = [:]
        for row in rows {
            var s = states[row.provider] ?? RowState()
            // The capsule is how full you are, i.e. what's left.
            s.target = CGFloat((row.reading.percentRemaining ?? 0) / 100)
            next[row.provider] = s
        }
        states = next

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard !reduce, !lowPower else {
            for k in Array(states.keys) {
                guard var st = states[k] else { continue }
                st.level = st.target
                st.velocity = 0
                st.phase = 0
                states[k] = st
            }
            stopLink()
            needsDisplay = true
            return
        }
        startLink()
    }

    // MARK: - Display link

    private func startLink() {
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick))
            // Ambient motion capped at 30fps — ProMotion would happily render
            // this at 120Hz and eat the battery we're monitoring.
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    private func stopLink() { link?.isPaused = true }

    @objc private func tick() {
        let k: CGFloat = 0.16, damping: CGFloat = 0.74
        var allSettled = true

        for id in Array(states.keys) {
            guard var s = states[id] else { continue }
            s.velocity = (s.velocity + (s.target - s.level) * k) * damping
            s.level += s.velocity
            let energy = min(1, abs(s.velocity) * 26)
            s.phase += 0.22 + energy * 0.5
            if s.settled {
                s.level = s.target
                s.velocity = 0
            } else {
                allSettled = false
            }
            states[id] = s
        }

        needsDisplay = true
        if allSettled { stopLink() }      // idle costs nothing from here
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // The window is transparent, so nothing erases the previous frame for
        // us — without this the label composites onto its own ghost every tick.
        ctx.clear(dirtyRect)
        guard !rows.isEmpty else { return }

        let onDark = isDarkBackdrop
        let reserved = showsLabel ? labelWidth : 0
        let barWidth = bounds.width - reserved - hPad * 2
        guard barWidth > 8 else { return }

        let h = rowHeight(for: rows.count)
        let total = h * CGFloat(rows.count) + rowGap * CGFloat(max(0, rows.count - 1))
        var y = (bounds.height + total) / 2 - h

        for row in rows {
            let rect = NSRect(x: hPad, y: y, width: barWidth, height: h)
            drawRow(ctx, row: row, in: rect, onDark: onDark)
            y -= h + rowGap
        }

        drawLabel(onDark: onDark, barRight: hPad + barWidth)
    }

    private func drawRow(_ ctx: CGContext, row: Row, in rect: NSRect, onDark: Bool) {
        let radius = rect.height / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(NSColor(white: onDark ? 1 : 0, alpha: 0.13).cgColor)
        ctx.fillPath()

        guard case .unavailable = row.reading else {
            drawFill(ctx, row: row, in: rect, radius: radius, onDark: onDark)
            return
        }
        // Unavailable reads as an empty dashed outline — visibly not zero.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(NSColor(white: onDark ? 1 : 0, alpha: 0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawFill(_ ctx: CGContext, row: Row, in rect: NSRect,
                          radius: CGFloat, onDark: Bool) {
        let s = states[row.provider] ?? RowState()
        // Colour still keys off consumption — green while there's room,
        // red as it runs out — but it's derived, never displayed.
        let tone = Tone.forUsage(row.reading.percentUsed ?? 0)

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()

        let energy = min(1, abs(s.velocity) * 26)
        let amp = energy * min(2.6, rect.height * 0.24)
        let x = rect.minX + rect.width * max(0, min(1, s.level))

        // Meniscus as a sampled sine, so the leading edge deforms rather than
        // sliding as a hard rectangle.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: rect.minX - 1, y: rect.maxY + 1))
        let steps = 10
        for i in stride(from: steps, through: 0, by: -1) {
            let f = CGFloat(i) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x + sin(s.phase + f * 3.1) * amp,
                                     y: rect.minY + rect.height * f))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        tone.gradient?.draw(in: rect, angle: 0)

        if rect.height >= 8 {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.34,
                            width: max(0, x - rect.minX), height: rect.height * 0.17))
        }
        ctx.restoreGState()

        // An inference must never look like a measurement.
        if !row.reading.isExact, s.level > 0.02 {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(white: onDark ? 1 : 0, alpha: 0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// One label for the whole stack: whichever agent has least left.
    private func drawLabel(onDark: Bool, barRight: CGFloat) {
        guard showsLabel,
              let worst = rows.min(by: { ($0.reading.percentRemaining ?? 101) < ($1.reading.percentRemaining ?? 101) }),
              !worst.label.isEmpty
        else { return }

        let text = worst.label as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor(white: onDark ? 1 : 0, alpha: 0.86)
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: barRight + 6, y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }

    /// The menu bar takes its appearance from the wallpaper behind it, so it can
    /// be light while the system is in dark mode. Read the view's effective
    /// appearance, never the global theme.
    private var isDarkBackdrop: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
