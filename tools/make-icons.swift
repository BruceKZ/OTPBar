// Draws the app icon and the menu bar icon.
// Usage: make-icons <output dir>  →  AppIcon.iconset/*.png, MenuBarIcon.png (36×36, template)
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

// Same palette as the countdown bar: red, orange, yellow, green, blue, purple.
let rainbow: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
    NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1),
]

func render(pixels: Int, _ draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx, scale)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// Ring of 30 cells (6 colors × 5) starting at 12 o'clock, going clockwise.
func drawRing(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, lit: Int,
              color: (Int) -> NSColor, dim: (Int) -> NSColor, glow: Bool) {
    let cells = 30
    let slot = 2 * CGFloat.pi / CGFloat(cells)
    let gap = slot * 0.28
    for i in 0..<cells {
        let start = CGFloat.pi / 2 - CGFloat(i) * slot - gap / 2
        let end = start - slot + gap
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.saveGState()
        let on = i < lit
        let c = on ? color(i) : dim(i)
        if on && glow { ctx.setShadow(offset: .zero, blur: 18, color: c.withAlphaComponent(0.7).cgColor) }
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: App icon — macOS standard grid: 1024 canvas, 824 body inset 100, continuous corners.

func appIcon(pixels: Int) -> NSBitmapImageRep {
    render(pixels: pixels) { ctx, _ in
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

        // Drop shadow under the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.setFill()
        shape.fill()
        ctx.restoreGState()

        // Graphite tile.
        ctx.saveGState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1),
                            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
            .draw(in: body, angle: -90)
        // Soft top sheen.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
            .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
        ctx.restoreGState()

        // Hairline edge.
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
        edge.lineWidth = 3
        edge.stroke()

        // Rainbow countdown ring, the purple band already used up.
        let center = CGPoint(x: 512, y: 512)
        drawRing(ctx, center: center, radius: 290, width: 62, lit: 25,
                 color: { rainbow[$0 / 5] }, dim: { _ in NSColor.white.withAlphaComponent(0.10) }, glow: true)

        // Lock in the middle.
        let lock = symbol("lock.fill", pointSize: 230, weight: .semibold, color: .white)
        let size = lock.size
        lock.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2 + 6,
                             width: size.width, height: size.height))
    }
}

// MARK: Menu bar icon — 18 pt template (black on transparent), drawn at 2×.

func menuBarIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let center = CGPoint(x: 18, y: 18)
    // Six arcs, one per color band; the last one hollow like a used-up band.
    let slot = 2 * CGFloat.pi / 6
    let gap = slot * 0.22
    for i in 0..<6 {
        let start = CGFloat.pi / 2 - CGFloat(i) * slot - gap / 2
        let path = CGMutablePath()
        path.addArc(center: center, radius: 14.5, startAngle: start, endAngle: start - slot + gap, clockwise: true)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(i == 5 ? 0.35 : 1).cgColor)
        ctx.setLineWidth(3.6)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
    }
    let lock = symbol("lock.fill", pointSize: 13, weight: .bold, color: .black)
    lock.draw(in: CGRect(x: center.x - lock.size.width / 2, y: center.y - lock.size.height / 2 + 0.5,
                         width: lock.size.width, height: lock.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(appIcon(pixels: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    write(appIcon(pixels: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
write(menuBarIcon(), to: outDir.appendingPathComponent("MenuBarIcon.png"))
print("icons written to \(outDir.path)")
