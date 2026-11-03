import AppKit

/// A tiny, invisible window of HyperSpace's own. macOS makes the display with the key window
/// the active one (where the menu bar is lit, new windows and Spotlight open), and moving the
/// pointer alone does not change it. On an empty workspace there is no window to focus, so
/// this one takes the key focus on that display instead. It never takes clicks.
final class FocusAnchor {
    private final class Panel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private lazy var window: NSWindow = {
        let window = Panel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return window
    }()

    private var shown = false

    /// Puts it in the middle of the visible area of `screen` (AX coordinates).
    func show(on screen: ScreenInfo) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = screen.visible.center
        window.setFrameOrigin(NSPoint(x: center.x, y: primaryHeight - center.y))
        window.orderFrontRegardless()
        shown = true
    }

    /// Once HyperSpace is frontmost: takes the key focus there.
    func takeKey() {
        guard shown else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard shown else { return }
        shown = false
        window.orderOut(nil)
    }
}
