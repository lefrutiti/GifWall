// Renders Resources/AppIcon.icns. Usage: swift Tools/make-icon.swift (or compile with swiftc and run).
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                           CGFloat(hex & 0xff) / 255, a])!
}

/// macOS-style continuous-corner squircle (superellipse corners).
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let n: CGFloat = 4, steps = 24
    func corner(_ cx: CGFloat, _ cy: CGFloat, _ from: CGFloat) {
        for i in 0...steps {
            let t = from + CGFloat(i) / CGFloat(steps) * .pi / 2
            let c = cos(t), s = sin(t)
            let x = cx + radius * copysign(pow(abs(c), 2 / n), c)
            let y = cy + radius * copysign(pow(abs(s), 2 / n), s)
            if p.isEmpty { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    corner(r.maxX - radius, r.minY + radius, -.pi / 2)
    corner(r.maxX - radius, r.maxY - radius, 0)
    corner(r.minX + radius, r.maxY - radius, .pi / 2)
    corner(r.minX + radius, r.minY + radius, .pi)
    p.closeSubpath()
    return p
}

/// Four-point sparkle with concave sides.
func sparkle(_ c: CGPoint, _ size: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k = size * 0.16
    p.move(to: CGPoint(x: c.x, y: c.y + size))
    p.addQuadCurve(to: CGPoint(x: c.x + size, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - size), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - size, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + size), control: CGPoint(x: c.x - k, y: c.y + k))
    return p
}

/// Ribbon between two offset sine curves; thickest in the middle, tapering toward the edges.
func ribbon(in r: CGRect, center: CGFloat, amp: CGFloat, thick: CGFloat, phase: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let steps = 120
    func y(_ u: CGFloat) -> CGFloat { r.minY + r.height * (center + amp * sin(2 * .pi * (u + phase))) }
    func t(_ u: CGFloat) -> CGFloat { r.height * thick * (0.35 + 0.65 * pow(sin(CGFloat.pi * min(1, max(0, u))), 1.4)) }
    var top: [CGPoint] = [], bottom: [CGPoint] = []
    for i in 0...steps {
        let u = CGFloat(i) / CGFloat(steps)
        let x = r.minX - r.width * 0.05 + u * r.width * 1.1
        top.append(CGPoint(x: x, y: y(u) + t(u) / 2))
        bottom.append(CGPoint(x: x, y: y(u) - t(u) / 2))
    }
    p.addLines(between: top)
    bottom.reversed().forEach { p.addLine(to: $0) }
    p.closeSubpath()
    return p
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body, radius: 250)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.22))
    ctx.addPath(shape); ctx.setFillColor(rgb(0xF08A7E)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // Base: pink top → coral bottom
    ctx.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xE79BB4), rgb(0xEE8C8E), rgb(0xF26A63)] as CFArray,
                                      locations: [0, 0.5, 1])!,
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Peach glow top-right, rosy glow top-left
    ctx.drawRadialGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xF8C29C, 0.95), rgb(0xF8C29C, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: body.maxX - 40, y: body.maxY - 60), startRadius: 0,
                           endCenter: CGPoint(x: body.maxX - 40, y: body.maxY - 60), endRadius: 560, options: [])
    ctx.drawRadialGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xE4A0C0, 0.7), rgb(0xE4A0C0, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: body.minX + 40, y: body.maxY - 40), startRadius: 0,
                           endCenter: CGPoint(x: body.minX + 40, y: body.maxY - 40), endRadius: 420, options: [])

    // Waves: soft glow, then a translucent white ribbon with a pink-tinted lower edge
    // Crest on the left (~u 0.3), trough on the right (~u 0.75), like the reference.
    for (center, alpha) in [(0.53 as CGFloat, 0.94 as CGFloat), (0.415, 0.74)] {
        let path = ribbon(in: body, center: center, amp: 0.1, thick: 0.08, phase: -0.02)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFFFFFF, 0.45))
        ctx.addPath(path); ctx.setFillColor(rgb(0xFFF1EE, alpha * 0.6)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let b = path.boundingBox
        ctx.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, alpha), rgb(0xFBD3D3, alpha * 0.85)] as CFArray,
                                          locations: [0, 1])!,
                               start: CGPoint(x: 0, y: b.maxY), end: CGPoint(x: 0, y: b.minY), options: [])
        ctx.restoreGState()
    }

    // Sparkles with a faint glow
    for (c, size) in [(CGPoint(x: body.minX + body.width * 0.66, y: body.minY + body.height * 0.76), 88.0 as CGFloat),
                      (CGPoint(x: body.minX + body.width * 0.30, y: body.minY + body.height * 0.25), 50.0)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.5, color: rgb(0xFFFFFF, 0.7))
        ctx.addPath(sparkle(c, size)); ctx.setFillColor(rgb(0xFFF6EE, 0.95)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Top sheen + hairline inner edge
    ctx.drawLinearGradient(CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.28)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                   (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let data = NSBitmapImageRep(cgImage: render(px)).representation(using: .png, properties: [:])!
    try! data.write(to: set.appendingPathComponent("icon_\(name).png"))
}
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "\(outDir)/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print("Wrote \(outDir)/AppIcon.icns")
