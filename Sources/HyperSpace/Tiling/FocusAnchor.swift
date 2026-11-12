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

    /// Clicks the desktop in the middle of the visible area of `screen`.
    func show(on screen: ScreenInfo) {
        point = screen.visible.center
        shown = true
        // Not right away: the windows of the workspace just left are still there for a moment,
        // and a click on one would focus its app and bring its workspace back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, shown else { return }
            click()
        }
    }

    func dismiss() {
        shown = false
    }

    /// Clicks the desktop, which brings the pointer to the middle of the display, and leaves
    /// it there (sent back where it was, it would visibly jump to the middle and back).
    /// Not while a button is held (a drag of yours would end), nor on a window that is there
    /// (a floating window, a scratchpad): its app would take the focus instead.
    private func click() {
        guard NSEvent.pressedMouseButtons == 0 else { return log.debug("empty display: no click, a button is held") }
        if let owner = Self.windowOwner(at: point) {
            return log.debug("empty display: no click, a window of \(owner, privacy: .public) is there")
        }
        Pointer.warp(to: point)
        Pointer.click([], at: point)
    }

    /// The app of an ordinary window (layer 0) on screen at `point`, if any; the desktop is not one.
    static func windowOwner(at point: CGPoint) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return list.first { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(point)
        }.map { $0[kCGWindowOwnerName as String] as? String ?? "?" }
    }
}
