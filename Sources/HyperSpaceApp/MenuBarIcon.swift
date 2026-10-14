import AppKit

/// The app icon's planet and orbit as an 18 pt template image, so macOS tints it for light
/// and dark menu bars. Drawn as vectors: sharp at any scale, no image assets.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let tilt = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: 25 * .pi / 180)
            let rx: CGFloat = 8.2, ry: CGFloat = 3.1, line: CGFloat = 1.25, planet: CGFloat = 3.7

            func orbit(front: Bool) -> CGPath {
                let path = CGMutablePath()
                let start: CGFloat = front ? .pi : 0
                for i in 0...90 {
                    let t = start + (front ? .pi : 2 * .pi) * CGFloat(i) / 90
                    let p = CGPoint(x: rx * cos(t), y: ry * sin(t)).applying(tilt)
                    i == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                return path
            }

            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineWidth(line)
            ctx.addPath(orbit(front: false))
            ctx.strokePath()

            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.fillEllipse(in: CGRect(x: center.x - planet, y: center.y - planet, width: 2 * planet, height: 2 * planet))
            ctx.setBlendMode(.clear) // gap where the orbit crosses in front of the planet
            ctx.setLineWidth(line + 1.6)
            ctx.addPath(orbit(front: true))
            ctx.strokePath()
            ctx.endTransparencyLayer()

            ctx.setBlendMode(.normal)
            ctx.setLineWidth(line)
            ctx.addPath(orbit(front: true))
            ctx.strokePath()

            let theta = -0.3 * CGFloat.pi
            let moon = CGPoint(x: rx * cos(theta), y: ry * sin(theta)).applying(tilt)
            ctx.fillEllipse(in: CGRect(x: moon.x - 1.7, y: moon.y - 1.7, width: 3.4, height: 3.4))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HyperSpace"
        return image
    }()
}
