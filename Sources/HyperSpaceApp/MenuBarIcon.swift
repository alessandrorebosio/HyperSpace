import AppKit

/// The app icon's tiling layout (one tall window, two stacked) as an 18 pt template image,
/// so macOS tints it for light and dark menu bars. Vector-drawn: no image assets.
enum MenuBarIcon {
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
}
