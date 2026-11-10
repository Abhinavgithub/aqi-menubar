import AppKit

/// Draws the app icon: an air-quality gauge in the six CPCB colours over a sky gradient,
/// with two drifting air lines. `AQIBar --render-icon <dir.iconset>` writes every size
/// macOS needs; make-icon.sh turns that into Resources/AppIcon.icns.
enum IconRenderer {
    static func draw(in rect: NSRect) {
        let s = rect.width
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }

        // macOS-style rounded square with a little margin, as Apple's icon grid does.
        let tile = NSRect(x: rect.minX + 0.1 * s, y: rect.minY + 0.1 * s, width: 0.8 * s, height: 0.8 * s)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 0.18 * s, yRadius: 0.18 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 0.02 * s
        shadow.shadowOffset = NSSize(width: 0, height: -0.008 * s)
        shadow.set()
        NSColor(srgbRed: 0.10, green: 0.36, blue: 0.62, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.78, blue: 0.95, alpha: 1),
                            NSColor(srgbRed: 0.12, green: 0.40, blue: 0.72, alpha: 1)])!
            .draw(in: tile, angle: -90)

        // Gauge: six CPCB segments on a 180° arc, Good on the left to Severe on the right.
        let center = p(0.5, 0.44)
        let radius = 0.25 * s, width = 0.075 * s
        let gap: CGFloat = 2.2
        for (i, c) in AQICategory.allCases.enumerated() {
            let start = 180 - CGFloat(i) * 30 - gap / 2
            let end = start - 30 + gap
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = width
            arc.lineCapStyle = .butt
            c.nsColor.setStroke()
            arc.stroke()
        }

        // Needle pointing into "Moderate".
        let angle: CGFloat = (180 - 75) * .pi / 180
        let tip = NSPoint(x: center.x + cos(angle) * (radius - width * 0.9), y: center.y + sin(angle) * (radius - width * 0.9))
        let needle = NSBezierPath()
        needle.move(to: center)
        needle.line(to: tip)
        needle.lineWidth = 0.028 * s
        needle.lineCapStyle = .round
        NSColor.white.setStroke()
        needle.stroke()
        let hub = 0.042 * s
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2)).fill()

        // Two drifting air lines under the gauge.
        for (y, inset, alpha) in [(0.30, 0.0, 0.95), (0.21, 0.07, 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
            let line = NSBezierPath()
            line.move(to: p(0.25 + inset, y))
            line.curve(to: p(0.50, y), controlPoint1: p(0.32 + inset, y + 0.045), controlPoint2: p(0.42, y + 0.045))
            line.curve(to: p(0.75 - inset, y), controlPoint1: p(0.58, y - 0.045), controlPoint2: p(0.68 - inset, y - 0.045))
            line.lineWidth = 0.03 * s
            line.lineCapStyle = .round
            NSColor.white.withAlphaComponent(alpha).setStroke()
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func png(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func run(directory: String) -> Int32 {
        _ = NSApplication.shared
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                guard let data = png(pixels: base * scale),
                      (try? data.write(to: dir.appendingPathComponent(name))) != nil else {
                    print("Failed to write \(name)"); return 1
                }
            }
        }
        print("Wrote iconset to \(dir.path)")
        return 0
    }
}
