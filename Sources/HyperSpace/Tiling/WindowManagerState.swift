import AppKit

/// Who has the focus and where the user works, as far as the window manager knows.
struct FocusState {
    /// The app focused last, to bring dialogs forward only when their app comes to the front.
    var frontPID: pid_t?
    /// Each watched app's focused window (0: none), kept from its focus notifications so that
    /// commands need no AX round trip (see `readFocused`).
    var focusedIn: [pid_t: CGWindowID] = [:]
    /// Counts each app's focus notifications: a lookup started before a newer one is dropped.
    var focusEpoch: [pid_t: Int] = [:]
    /// The window focused last in each workspace: focused again when the workspace is.
    var lastFocused: [Int: CGWindowID] = [:]
    /// Focus changes we cause ourselves must not switch workspace back: none is followed
    /// until then.
    var followAfter = Date.distantPast
    /// A window just moved to a hidden workspace that still has focus: it must not drag
    /// its workspace onto the screen. Cleared as soon as focus goes elsewhere.
    var movedAway: CGWindowID?
    /// The display the user works on, set when we move the focus there: an empty workspace
    /// has no window to tell, and the pointer may still be on the other display.
    var activeDisplay: CGDirectDisplayID?
    /// The display of an empty workspace holding the focus (the focus anchor is there): the
    /// display you work on, even while the window left behind still looks focused to macOS.
    var heldDisplay: CGDirectDisplayID?
    /// Counts focus requests, so a retry of an old one gives up.
    var request = 0
}

/// A modifier-drag: the window it moves or resizes, and the writes on their way to its app.
struct DragState {
    /// The drag in progress, once the window under the pointer is known.
    var session: DragSession?
    /// Dragging writes to the app on its AX queue, one write at a time with only the latest
    /// point waiting; `generation` tells the writes of an old drag from the current one.
    var writeInFlight = false
    var pendingPoint: CGPoint?
    var generation = 0
    /// The window under the pointer is being looked up (off the main thread) for a new drag;
    /// a release meanwhile is kept and played once it is found.
    var starting = false
    var endedEarly: CGPoint?
}

/// The windows found after a start being matched to the workspaces saved last time.
struct RestoreSession {
    /// The workspaces saved last time, while the windows found at start are matched to them.
    var restorer: WorkspaceRestorer?
    var state: WorkspaceState?
    /// The saved window (its index in `state`) each restored window was.
    var index: [CGWindowID: Int] = [:]
    /// Restored windows whose saved order and column were applied: never again, so what you
    /// arrange afterwards is not undone by a later look for windows (a Space change).
    var applied: Set<CGWindowID> = []
    /// Counts the restores, so the timer that ends one cannot end a later one.
    var generation = 0
}

/// The looks for windows on the apps' AX queues, and the run (start to stop) they belong to.
struct DiscoveryState {
    /// Counts the runs, so a lookup of an earlier run is not counted in this one.
    var run = 0
    /// Window lookups still running on the apps' AX queues, and what waits for them.
    var pending = 0
    var waiting: [() -> Void] = []
    /// Running apps are being picked up at start: retile once they all are.
    var adopting = false
    /// Windows of each app looked at and found to be nothing to manage (popovers, sheets, the
    /// desktop): not described again by every look for windows. Forgotten on a rescan.
    var rejected: [pid_t: Set<CGWindowID>] = [:]
    /// The windows that existed when this run started: one of them found where no display
    /// shows it was left there by an earlier run (see `track`).
    var windowsAtStart: Set<CGWindowID> = []
}
