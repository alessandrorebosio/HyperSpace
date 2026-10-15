import AppKit

/// Menu bar images, vector-drawn as template images so macOS tints them for light and dark
/// menu bars. No image assets.
@MainActor
enum MenuBarIcon {
    /// The app icon's tiling layout (one tall window, two stacked), 18 pt.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for tile in [NSRect(x: 1.5, y: 2, width: 6.5, height: 14),
                         NSRect(x: 9.5, y: 9.75, width: 7, height: 6.25),
                         NSRect(x: 9.5, y: 2, width: 7, height: 6.25)] {
                NSBezierPath(roundedRect: tile, xRadius: 1.8, yRadius: 1.8).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "HyperSpace"
        return image
    }()

    /// Labels already drawn, by mode and workspace: refreshing costs a dictionary lookup.
    private static var labels: [String: NSImage] = [:]

    /// AeroSpace's i3-style label: outside the main mode, the mode's initial in a circle and
    /// a colon; then the focused workspace knocked out of a rounded box.
    static func label(workspace: String, mode: String?) -> NSImage {
        let key = (mode ?? "") + "\u{0}" + workspace
        if let cached = labels[key] { return cached }

        let height: CGFloat = 18, padding: CGFloat = 4, gap: CGFloat = 3
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.black]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black]
        let name = workspace as NSString
        let initial = mode.map { $0.prefix(1).uppercased() as NSString }
        let colon = ":" as NSString
        let colonWidth = ceil(colon.size(withAttributes: bold).width)
        let modeWidth = initial == nil ? 0 : (height - 2) + gap + colonWidth + gap
        let boxWidth = max(ceil(name.size(withAttributes: bold).width) + padding * 2, height - 2) // square at least
        let size = NSSize(width: modeWidth + boxWidth, height: height)

        func draw(_ text: NSString, _ attributes: [NSAttributedString.Key: Any], centeredIn rect: NSRect) {
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()
            if let initial {
                let circle = NSRect(x: 1, y: 1, width: height - 2, height: height - 2)
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
                draw(initial, small, centeredIn: circle)
                draw(colon, bold, centeredIn: NSRect(x: circle.maxX + gap, y: 0, width: colonWidth, height: height))
            }
            let box = NSRect(x: modeWidth, y: 1, width: boxWidth, height: height - 2)
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            draw(name, bold, centeredIn: box)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = mode.map { "\($0) mode, workspace \(workspace)" } ?? "Workspace \(workspace)"
        labels[key] = image
        return image
    }
}
