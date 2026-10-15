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

    /// Labels already drawn, by mode and workspaces: refreshing costs a dictionary lookup.
    private static var labels: [String: NSImage] = [:]

    /// AeroSpace's i3-style label: outside the main mode, the mode's initial in a circle and
    /// a colon; then each display's workspace, the main display first, the others left to
    /// right, divided by a bar (`1 | develop`): the focused one knocked out of a rounded box, the others outlined.
    /// Opaque, not a template: the menu bar draws template images translucent. The handler
    /// runs at every draw, so the color follows the menu bar's light or dark appearance.
    static func label(workspaces: [(name: String, focused: Bool)], mode: String?) -> NSImage {
        let key = (mode ?? "") + workspaces.map { "\u{0}" + ($0.focused ? "*" : "") + $0.name }.joined()
        if let cached = labels[key] { return cached }
        if labels.count > 64 { labels = [:] } // modes x workspaces x displays: keep it small

        let height: CGFloat = 18, padding: CGFloat = 4, gap: CGFloat = 3, divider: CGFloat = 1
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.black]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black]
        let initial = mode.map { $0.prefix(1).uppercased() as NSString }
        let colon = ":" as NSString
        let colonWidth = ceil(colon.size(withAttributes: bold).width)
        let modeWidth = initial == nil ? 0 : (height - 2) + gap + colonWidth + gap
        // Each workspace's box, square at least, with a divider between neighbors.
        var boxes: [(name: NSString, focused: Bool, rect: NSRect)] = []
        var x = modeWidth
        for (i, workspace) in workspaces.enumerated() {
            if i > 0 { x += gap + divider + gap }
            let name = workspace.name as NSString
            let width = max(ceil(name.size(withAttributes: bold).width) + padding * 2, height - 2)
            boxes.append((name, workspace.focused, NSRect(x: x, y: 1, width: width, height: height - 2)))
            x += width
        }
        let size = NSSize(width: x, height: height)

        func draw(_ text: NSString, _ attributes: [NSAttributedString.Key: Any], centeredIn rect: NSRect) {
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        }

        let image = NSImage(size: size, flipped: false) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ink = dark ? NSColor.white : NSColor.black
            ink.set()
            if let initial {
                let circle = NSRect(x: 1, y: 1, width: height - 2, height: height - 2)
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
                draw(initial, small.merging([.foregroundColor: ink]) { $1 }, centeredIn: circle)
                draw(colon, bold.merging([.foregroundColor: ink]) { $1 }, centeredIn: NSRect(x: circle.maxX + gap, y: 0, width: colonWidth, height: height))
            }
            for (i, box) in boxes.enumerated() {
                if i > 0 {
                    NSRect(x: box.rect.minX - gap - divider, y: 4, width: divider, height: height - 8).fill()
                }
                if box.focused {
                    // Knocked out: the text is cut from the box, so the menu bar shows through.
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: box.rect, xRadius: 4, yRadius: 4).fill()
                    NSGraphicsContext.current?.compositingOperation = .destinationOut
                    draw(box.name, bold, centeredIn: box.rect)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    let outline = NSBezierPath(roundedRect: box.rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
                    outline.lineWidth = 1.5
                    outline.stroke()
                    draw(box.name, bold.merging([.foregroundColor: ink]) { $1 }, centeredIn: box.rect)
                }
            }
            return true
        }
        let names = workspaces.map { $0.focused ? "workspace \($0.name) (focused)" : "workspace \($0.name)" }.joined(separator: ", ")
        image.accessibilityDescription = mode.map { "\($0) mode, \(names)" } ?? names
        labels[key] = image
        return image
    }
}
