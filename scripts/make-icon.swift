#!/usr/bin/env swift
// Draws the HyperSpace app icon (a planet with its orbit) and writes Resources/AppIcon.icns.
// Usage: scripts/make-icon.swift   (needs only the Command Line Tools)
import AppKit

let accent = NSColor(srgbRed: 0.49, green: 0.62, blue: 1.0, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024 // design on a 1024 grid

    // Body: macOS icon grid, 824 pt squircle with a deep night gradient.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(srgbRed: 0.11, green: 0.13, blue: 0.25, alpha: 1),
               ending: NSColor(srgbRed: 0.03, green: 0.04, blue: 0.09, alpha: 1))!
        .draw(in: squircle, angle: -90)

    // Orbit: a tilted ellipse around the planet. Its back half is hidden by the planet,
    // its front half crosses over it with a small gap cut out of the planet.
    let center = CGPoint(x: 512 * s, y: 512 * s)
    let tilt = 25 * CGFloat.pi / 180
    let rx = 300 * s, ry = 112 * s, line = 26 * s, gap = 18 * s
    let planetRadius = 128 * s

    func orbitPath(frontOnly: Bool) -> CGPath {
        let path = CGMutablePath()
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
        let steps = 180
        let range: ClosedRange<CGFloat> = frontOnly ? (CGFloat.pi...2 * CGFloat.pi) : (0...2 * CGFloat.pi)
        for i in 0...steps {
            let t = range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: rx * cos(t), y: ry * sin(t)).applying(transform)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    // Opaque, so the front arc drawn twice looks the same as the back one.
    ctx.setStrokeColor(NSColor(srgbRed: 0.86, green: 0.88, blue: 0.94, alpha: 1).cgColor)
    ctx.setLineWidth(line)
    ctx.addPath(orbitPath(frontOnly: false))
    ctx.strokePath()

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - planetRadius, y: center.y - planetRadius,
                               width: 2 * planetRadius, height: 2 * planetRadius))
    ctx.setBlendMode(.clear) // cut the gap out of the planet only
    ctx.setLineWidth(line + 2 * gap)
    ctx.addPath(orbitPath(frontOnly: true))
    ctx.strokePath()
    ctx.endTransparencyLayer()

    // Re-draw the front arc on top of the cut planet (round caps hide the joins).
    ctx.setBlendMode(.normal)
    ctx.setLineCap(.round)
    ctx.setLineWidth(line)
    ctx.addPath(orbitPath(frontOnly: true))
    ctx.strokePath()

    // Moon on the front right of the orbit.
    let theta = -0.3 * CGFloat.pi
    let moon = CGPoint(x: rx * cos(theta), y: ry * sin(theta))
        .applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt))
    let moonRadius = 38 * s
    ctx.setFillColor(accent.cgColor)
    ctx.fillEllipse(in: CGRect(x: moon.x - moonRadius, y: moon.y - moonRadius, width: 2 * moonRadius, height: 2 * moonRadius))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appending(path: name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appending(path: "Resources/AppIcon.png")) // preview

let output = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
