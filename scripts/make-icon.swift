import AppKit
import CoreGraphics

// Generates Headroom.icns.
//
// The motif matches the menu bar glyph — an arc gauge with a needle — so the
// Dock icon and the status item read as the same object. The arc carries the
// app's semantic ramp (green while there's room, red as it runs out), which is
// the one idea the whole app is built around.
//
// Each size is rendered natively rather than downscaled: at 16pt a downscaled
// needle turns to mush, so the small sizes get proportionally heavier strokes.

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func srgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
}

let bodyTop    = srgb(38, 46, 51)
let bodyBottom = srgb(16, 20, 22)
let ok         = srgb(75, 227, 155)
let warn       = srgb(255, 205, 110)
let crit       = srgb(255, 122, 107)
let trackColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13)

/// Blend across the ramp: green → amber → red.
func rampColor(_ t: Double) -> CGColor {
    func mix(_ a: CGColor, _ b: CGColor, _ f: Double) -> CGColor {
        let ac = a.components!, bc = b.components!
        return CGColor(srgbRed: ac[0] + (bc[0] - ac[0]) * f,
                       green:   ac[1] + (bc[1] - ac[1]) * f,
                       blue:    ac[2] + (bc[2] - ac[2]) * f,
                       alpha: 1)
    }
    return t < 0.5 ? mix(ok, warn, t / 0.5) : mix(warn, crit, (t - 0.5) / 0.5)
}

func render(size px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // macOS icon grid: the body sits inset inside the canvas with a squircle-ish
    // radius, so it lines up with every other icon in the Dock.
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2245

    ctx.saveGState()
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [bodyTop, bodyBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])
    ctx.restoreGState()

    // Gauge geometry. The dial sits slightly above centre so the needle's pivot
    // and the arc are optically balanced inside the rounded square.
    let centre = CGPoint(x: body.midX, y: body.midY - body.height * 0.10)
    let arcR = body.width * 0.315
    // Heavier strokes at small sizes, or the arc disappears in the menu of icons.
    let weight: CGFloat = px <= 32 ? 0.30 : (px <= 64 ? 0.26 : 0.225)
    let lineW = arcR * weight

    let startA = CGFloat.pi * 0.97      // just past 9 o'clock
    let endA   = CGFloat.pi * 0.03      // just before 3 o'clock

    // Track behind the ramp, so the gauge reads as a dial even at 16px.
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineW)
    ctx.setStrokeColor(trackColor)
    ctx.addArc(center: centre, radius: arcR, startAngle: startA, endAngle: endA,
               clockwise: true)
    ctx.strokePath()

    // The ramp, drawn as overlapping segments — CoreGraphics can't gradient a
    // stroke directly, and segments stay crisp at every size.
    let steps = max(24, px / 8)
    for i in 0..<steps {
        let t0 = Double(i) / Double(steps)
        let t1 = Double(i + 1) / Double(steps)
        let a0 = startA + (endA - startA) * CGFloat(t0)
        let a1 = startA + (endA - startA) * CGFloat(t1 + 0.02)
        ctx.setStrokeColor(rampColor(t0))
        ctx.setLineCap(i == 0 || i == steps - 1 ? .round : .butt)
        ctx.setLineWidth(lineW)
        ctx.addArc(center: centre, radius: arcR, startAngle: a0, endAngle: a1, clockwise: true)
        ctx.strokePath()
    }

    // Needle, pointing into the green — this is a gauge with room left, which is
    // the state the app hopes to keep you in.
    let needleA = startA + (endA - startA) * 0.30
    let tip = CGPoint(x: centre.x + cos(needleA) * arcR * 0.80,
                      y: centre.y + sin(needleA) * arcR * 0.80)
    let hubR = arcR * (px <= 32 ? 0.20 : 0.155)

    ctx.setLineCap(.round)
    ctx.setLineWidth(hubR * (px <= 32 ? 1.15 : 0.95))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.move(to: centre)
    ctx.addLine(to: tip)
    ctx.strokePath()

    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: centre.x - hubR, y: centre.y - hubR,
                               width: hubR * 2, height: hubR * 2))
    ctx.setFillColor(bodyBottom)
    let inner = hubR * 0.42
    ctx.fillEllipse(in: CGRect(x: centre.x - inner, y: centre.y - inner,
                               width: inner * 2, height: inner * 2))

    return ctx.makeImage()!
}

// Standard iconset ladder.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for v in variants {
    let image = render(size: v.px)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: v.px, height: v.px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try! data.write(to: out.appendingPathComponent("\(v.name).png"))
}
print("wrote \(variants.count) sizes to \(out.path)")
