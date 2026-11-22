import AppKit

/// Makes a display with no window to focus the active one (where the menu bar is lit, new
/// windows and Spotlight open). Moving the pointer alone does not change it, and a background
/// app cannot make itself active there (macOS ignores NSApp.activate, and AX, from it).
///
/// HyperSpace clicks the empty desktop in the middle of that display, as you would: the
/// Finder, which owns the desktop, becomes the active app there and the keyboard leaves the
/// window on the other display. (A window of HyperSpace's own clicked there made HyperSpace
/// active, but macOS 27 no longer lights the menu bar of an accessory app's display.)
final class FocusAnchor {
    /// Whether the focus is held on an empty display (until `dismiss`).
    private(set) var shown = false
    /// Where the click goes, in AX (top-left) coordinates.
    private var point = CGPoint.zero

    /// Counts the calls of `show`, so the click of an earlier one is not sent as well (two
    /// clicks at the same point would be a double click on the desktop).
    private var request = 0

    /// How long after `show` the click is tried, each time waiting since the try before: the
    /// windows of the workspace just left are still there for a moment (an app slow to move
    /// them, longer), and a click on one would focus its app and bring its workspace back.
    static let clickDelays: [TimeInterval] = [0.05, 0.1, 0.2]

    /// Clicks the desktop in the middle of the visible area of `screen`.
    func show(on screen: ScreenInfo) {
        point = screen.visible.center
        shown = true
        request += 1
        tryClick(request, after: Self.clickDelays[...])
    }

    func dismiss() {
        shown = false
    }

    /// Clicks once the point is free, looking again after each of `delays` while it is not.
    private func tryClick(_ request: Int, after delays: ArraySlice<TimeInterval>) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, shown, request == self.request, !click() else { return }
            tryClick(request, after: delays.dropFirst())
        }
    }

    /// Clicks the desktop, which brings the pointer to the middle of the display, and leaves
    /// it there (sent back where it was, it would visibly jump to the middle and back).
    /// Not while a button is held (a drag of yours would end), nor on a window that is there
    /// (a floating window, a scratchpad): its app would take the focus instead. Returns
    /// whether it clicked.
    private func click() -> Bool {
        guard NSEvent.pressedMouseButtons == 0 else {
            log.debug("empty display: no click, a button is held")
            return false
        }
        if let owner = Self.windowOwner(at: point) {
            log.debug("empty display: no click, a window of \(owner, privacy: .public) is there")
            return false
        }
        Pointer.warp(to: point)
        Pointer.click([], at: point)
        return true
    }

    /// The app of an ordinary window (layer 0) on screen at `point`, if any; the desktop is not one.
    static func windowOwner(at point: CGPoint) -> String? {
        WindowList.onScreen().first { $0.bounds.contains(point) }.map { $0.owner ?? "?" }
    }
}
