import AppKit

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    var isFloating = false
    /// A dialog (or dialog-like window: no zoom, no full screen): always floats unless toggled by hand.
    var isDialog = false
    /// The window a dialog belongs to: it shares its workspace and comes to the front with it.
    var parent: CGWindowID?
    /// Set once the user toggles floating by hand; config reloads then leave it alone.
    var userOverride = false
    var workspace = 0
    /// Where the window was before its workspace was hidden.
    var hiddenFrame: CGRect?
    /// Share of the split it is in (stack or columns), changed by resizing.
    var weight: CGFloat = 1
    /// When we last moved it: the moves this causes are ours, not the user's.
    var movedByUs = Date.distantPast
    /// Out of the tiling and the workspaces: shown centered above the others on demand.
    var scratchpad = false
    /// A scratchpad window on screen (it stays there across workspace switches).
    var scratchpadShown = false
    /// When it last had the focus: tells which window of its app you work in.
    var focusedAt = Date.distantPast
    /// The title as last read (when found, then on every title change notification), so the
    /// menu and the floating rules need no AX round trip on the main thread.
    var title: String?

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, bundleID: String?) {
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
    }
}
