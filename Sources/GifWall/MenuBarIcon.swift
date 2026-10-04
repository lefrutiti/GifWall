import AppKit

/// Template menu bar icon: two waves with a small sparkle (matches the app icon).
/// Drawn in code so it stays crisp at any scale and follows the menu bar's light/dark tint.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            for baseY in [9.6, 5.8] as [CGFloat] {
                let wave = NSBezierPath()
                wave.lineWidth = 1.35
                wave.lineCapStyle = .round
                let left: CGFloat = 1.5, right: CGFloat = 16.5, amp: CGFloat = 1.7
                let steps = 40
                for i in 0...steps {
                    let u = CGFloat(i) / CGFloat(steps)
                    let p = NSPoint(x: left + u * (right - left), y: baseY + amp * sin(2 * .pi * (u - 0.02)))
                    i == 0 ? wave.move(to: p) : wave.line(to: p)
                }
                wave.stroke()
            }

            let c = NSPoint(x: 13.6, y: 14.4), r: CGFloat = 2.6, k: CGFloat = 0.45
            let star = NSBezierPath()
            star.move(to: NSPoint(x: c.x, y: c.y + r))
            star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
            star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
            star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
            star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
            star.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GifWall"
        return image
    }()
}
