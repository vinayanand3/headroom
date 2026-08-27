import AppKit
import QuartzCore

/// One line of the menu: window name, a drain capsule, and what's left.
///
/// This is where the Wave Meniscus belongs. In the menu bar it had to survive at
/// 5pt tall beside a number it could contradict; here it gets real width, sits
/// next to its own label, and — the part that matters — it only animates while
/// the menu is open. Opening the menu is an explicit user action, so the motion
/// marks something real and costs exactly nothing the rest of the time.
final class MenuRowView: NSView {

    private let title: String
    private var reading: Reading = .unavailable(reason: "…")
    private var detail: String = ""

    // Spring state — velocity drives the slosh, so it goes glassy when settled.
    private var level: CGFloat = 0
    private var target: CGFloat = 0
    private var velocity: CGFloat = 0
    private var phase: CGFloat = 0
    private var link: CADisplayLink?

    private let capsuleWidth: CGFloat = 104
    private let capsuleHeight: CGFloat = 9
    private let titleWidth: CGFloat = 74
    private let inset: CGFloat = 21

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func configure(reading: Reading, detail: String) {
        self.reading = reading
        self.detail = detail
        target = CGFloat((reading.percentRemaining ?? 0) / 100)
        needsDisplay = true
    }

    /// Replay the fill from empty each time the menu opens. Cheap, bounded, and
    /// it makes the level legible as motion rather than only as a static edge.
    func replay() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            level = target; velocity = 0; needsDisplay = true; return
        }
        level = 0
        velocity = 0
        phase = 0
        startLink()
    }

    private func startLink() {
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            // .common so it keeps ticking while the menu holds the run loop in
            // event-tracking mode — otherwise it freezes exactly when it's visible.
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    func stop() { link?.isPaused = true }

    @objc private func tick() {
        let k: CGFloat = 0.16, damping: CGFloat = 0.74
        velocity = (velocity + (target - level) * k) * damping
        level += velocity
        phase += 0.22 + min(1, abs(velocity) * 26) * 0.5
        needsDisplay = true

        if abs(target - level) < 0.0008 && abs(velocity) < 0.0008 {
            level = target
            velocity = 0
            stop()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let font = NSFont.menuFont(ofSize: 13)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let midY = bounds.midY
        (title as NSString).draw(
            at: NSPoint(x: inset, y: midY - font.pointSize * 0.62),
            withAttributes: titleAttrs)

        let capsuleX = inset + titleWidth
        let rect = NSRect(x: capsuleX, y: midY - capsuleHeight / 2,
                          width: capsuleWidth, height: capsuleHeight)
        drawCapsule(ctx, in: rect)

        (detail as NSString).draw(
            at: NSPoint(x: capsuleX + capsuleWidth + 12, y: midY - 6.5),
            withAttributes: detailAttrs)
    }

    private func drawCapsule(_ ctx: CGContext, in rect: NSRect) {
        let radius = rect.height / 2
        let track = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.addPath(track)
        ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
        ctx.fillPath()

        guard case .unavailable = reading else {
            ctx.saveGState()
            ctx.addPath(track)
            ctx.clip()

            let amp = min(1, abs(velocity) * 26) * 2.0
            let x = rect.minX + rect.width * max(0, min(1, level))

            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 1))
            path.addLine(to: CGPoint(x: rect.minX - 1, y: rect.maxY + 1))
            let steps = 10
            for i in stride(from: steps, through: 0, by: -1) {
                let f = CGFloat(i) / CGFloat(steps)
                path.addLine(to: CGPoint(x: x + sin(phase + f * 3.1) * amp,
                                         y: rect.minY + rect.height * f))
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.clip()
            Tone.forUsage(reading.percentUsed ?? 0).gradient?.draw(in: rect, angle: 0)

            ctx.setFillColor(NSColor(white: 1, alpha: 0.2).cgColor)
            ctx.fill(CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.36,
                            width: max(0, x - rect.minX), height: rect.height * 0.18))
            ctx.restoreGState()
            // Solid meniscus for everything. Measured vs inferred is carried by
            // the "~" on the number and the "estimated" note under the rows,
            // rather than by a texture people have to decode.
            return
        }

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [2.5, 2.5])
        ctx.strokePath()
        ctx.restoreGState()
    }
}
