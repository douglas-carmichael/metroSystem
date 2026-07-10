import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(deviceRed: r, green: g, blue: b, alpha: a)
}

// App palette (RetroTheme).
let amber       = rgb(1.00, 0.72, 0.20)
let amberBright = rgb(1.00, 0.86, 0.45)
let green       = rgb(0.36, 1.00, 0.42)
let cyan        = rgb(0.45, 0.95, 1.00)

/// Draw the icon at `px`×`px`. All geometry is authored in a 1024 grid and
/// scaled by k, so every size renders natively (crisp, not downscaled).
func makeIcon(_ px: Int) -> Data {
    let S = CGFloat(px)
    let k = S / 1024.0
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    let center = CGPoint(x: 512 * k, y: 512 * k)

    // --- Rounded "screen" body ---
    let margin: CGFloat = 96 * k
    let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = 182 * k
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    bodyPath.addClip()

    // Dark phosphor gradient.
    NSGradient(colors: [rgb(0.03, 0.03, 0.045), rgb(0.10, 0.10, 0.13)])!
        .draw(in: body, angle: 90)

    // Soft central amber bloom.
    NSGradient(colors: [rgb(1.0, 0.72, 0.20, 0.16), rgb(1.0, 0.72, 0.20, 0.0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 430 * k, options: [])

    // Faint CRT scanlines.
    rgb(0, 0, 0, 0.16).set()
    var y = body.minY
    while y < body.maxY {
        NSBezierPath(rect: CGRect(x: body.minX, y: y, width: body.width, height: 3 * k)).fill()
        y += 9 * k
    }
    ctx.restoreGState()

    // --- Circular VAL line ---
    let R = 250 * k
    func onRing(_ deg: CGFloat, _ rr: CGFloat = 0) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: center.x + (R + rr) * cos(a), y: center.y + (R + rr) * sin(a))
    }

    // Track ring: outer bloom, body, hot inner core.
    let ring = NSBezierPath(); ring.appendOval(in: CGRect(x: center.x - R, y: center.y - R, width: 2 * R, height: 2 * R))
    ctx.setShadow(offset: .zero, blur: 46 * k, color: amber.withAlphaComponent(0.95).cgColor)
    amber.set(); ring.lineWidth = 26 * k; ring.stroke()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    amberBright.set(); ring.lineWidth = 9 * k; ring.stroke()

    // Six station markers on the ring.
    ctx.setShadow(offset: .zero, blur: 16 * k, color: cyan.withAlphaComponent(0.9).cgColor)
    for deg in stride(from: CGFloat(30), through: 330, by: 60) {
        let p = onRing(deg)
        let d = 22 * k
        cyan.set()
        NSBezierPath(ovalIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)).fill()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Train car sitting on the ring (green), tangent to the loop.
    let tDeg: CGFloat = 0
    let tp = onRing(tDeg)
    ctx.saveGState()
    ctx.translateBy(x: tp.x, y: tp.y)
    ctx.rotate(by: (tDeg + 90) * .pi / 180)
    ctx.setShadow(offset: .zero, blur: 34 * k, color: green.withAlphaComponent(0.95).cgColor)
    green.set()
    NSBezierPath(roundedRect: CGRect(x: -52 * k, y: -21 * k, width: 104 * k, height: 42 * k),
                 xRadius: 15 * k, yRadius: 15 * k).fill()
    ctx.restoreGState()

    // PCC hub: an amber diamond at the loop centre.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: .pi / 4)
    ctx.setShadow(offset: .zero, blur: 22 * k, color: amber.withAlphaComponent(0.9).cgColor)
    let h = 42 * k
    amber.set(); NSBezierPath(rect: CGRect(x: -h / 2, y: -h / 2, width: h, height: h)).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    amberBright.set()
    let hi = 20 * k
    NSBezierPath(rect: CGRect(x: -hi / 2, y: -hi / 2, width: hi, height: hi)).fill()
    ctx.restoreGState()

    // Thin screen bezel.
    amber.withAlphaComponent(0.30).set()
    let bez = NSBezierPath(roundedRect: body.insetBy(dx: 6 * k, dy: 6 * k),
                           xRadius: radius - 6 * k, yRadius: radius - 6 * k)
    bez.lineWidth = 4 * k; bez.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Args: sizes to emit as "path:px" pairs, or just render the 1024 master.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let data = makeIcon(s)
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(s).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}
