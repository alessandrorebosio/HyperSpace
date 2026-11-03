import AppKit

/// A tiny, invisible window of HyperSpace's own. macOS makes the display with the key window
/// the active one (where the menu bar is lit, new windows and Spotlight open), and moving the
/// pointer alone does not change it. On an empty workspace there is no window to focus, so
/// this one takes the key focus on that display instead. It never takes clicks.
///
/// A non-activating panel: it can become key while HyperSpace is still in the background,
/// so the keyboard leaves the window on the other display even when macOS refuses to bring
/// HyperSpace to the front.
final class FocusAnchor: NSObject, NSWindowDelegate {
    /// Called when something else takes the key focus (a click, ⌘Tab, an app opening).
    var onResign: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private lazy var window: NSWindow = {
        let window = Panel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.delegate = self
        return window
    }()

    private(set) var shown = false

    /// Puts it in the middle of the visible area of `screen` (AX coordinates).
    func show(on screen: ScreenInfo) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = screen.visible.center
        window.setFrameOrigin(NSPoint(x: center.x, y: primaryHeight - center.y))
        window.orderFrontRegardless()
        shown = true
        // Non-activating: it takes the keyboard at once, HyperSpace frontmost or not.
        window.makeKey()
    }

    /// Once HyperSpace is frontmost: takes the key focus there (again, now as the active app).
    func takeKey() {
        guard shown else { return }
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard shown else { return }
        shown = false
        window.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming key again as the active app resigns it for a moment: only a real loss counts.
        DispatchQueue.main.async { [weak self] in
            guard let self, shown, !window.isKeyWindow else { return }
            dismiss()
            onResign?()
        }
    }
}
