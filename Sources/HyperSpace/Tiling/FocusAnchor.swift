import AppKit

/// A tiny, invisible window of HyperSpace's own. macOS makes the display of the active app's
/// key window the active one (where the menu bar is lit, new windows and Spotlight open), and
/// moving the pointer alone does not change it. On an empty workspace there is no window to
/// focus, so this one takes the focus on that display instead.
///
/// A background app cannot make itself active (macOS ignores NSApp.activate, and AX, from
/// it), and a key window of an inactive app leaves the menu bar on the other display. A click
/// is what macOS always honours: HyperSpace clicks its own window, which activates it there.
final class FocusAnchor: NSObject, NSWindowDelegate {
    /// Called when something else takes the key focus (a click, ⌘Tab, an app opening).
    var onResign: (() -> Void)?

    private final class Panel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private lazy var window: NSWindow = {
        let window = Panel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless],
                           backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        // Explicitly false: the whole window takes clicks, transparent as it is.
        window.ignoresMouseEvents = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // Above any window that could be there, so the click lands on it.
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        window.delegate = self
        return window
    }()

    private(set) var shown = false
    /// Where the window is, in AX (top-left) coordinates.
    private var point = CGPoint.zero

    /// Puts it in the middle of the visible area of `screen` (AX coordinates) and makes
    /// HyperSpace active there.
    func show(on screen: ScreenInfo) {
        let center = screen.visible.center
        point = center
        window.setFrameOrigin(NSPoint(x: center.x - 1, y: ScreenInfo.primaryHeight - center.y - 1))
        window.orderFrontRegardless()
        shown = true
        window.makeKey()
        // Clicked once it is really on screen: sent right away, the click can land on the
        // window of the workspace just left (still there for a moment), whose app would
        // then take the focus and bring its workspace back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, shown else { return }
            click()
        }
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

    /// Clicks the window, which brings the pointer to the middle of the display, and leaves
    /// it there (sent back where it was, it would visibly jump to the middle and back).
    /// Not while a button is held (a drag of yours would end).
    private func click() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        Pointer.warp(to: point)
        Pointer.click([], at: point)
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
