import AppKit
import ApplicationServices
import HyperSpaceCore
import Synchronization

/// What the window manager needs to know about a window, read once when it appears.
struct WindowRecord: @unchecked Sendable {
    let id: WindowID
    let element: AXUIElement
    let floating: Bool
    let frame: CGRect?
    /// Kept up to date through title notifications, for rules and `list-windows`.
    var title: String
    /// Shows a tab bar: with macOS native tabs every tab is a window of its own.
    let hasTabs: Bool
}

/// One running app as the window manager sees it. Every AX call to the app runs on the
/// app's own serial queue, so apps are driven concurrently and a slow or frozen app only
/// delays itself (calls also time out after `timeout`). Notifications arrive on the main
/// run loop and are forwarded to `events`.
final class AXApp: @unchecked Sendable {
    enum Event {
        case windowCreated(AXUIElement)
        case windowDestroyed(WindowID)
        case focusChanged
        case minimized(WindowID, Bool)
        case moved(WindowID)
        case titleChanged(WindowID)
    }

    /// Seconds an AX call may take before the app counts as unresponsive.
    static let timeout: Float = 1

    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement
    let queue: DispatchQueue
    /// Per window, how many frames were requested: a queued frame older than the latest is
    /// skipped. Shared by the main thread (requests) and the queue (applies).
    let generations = Mutex<[WindowID: Int]>([:])
    private var observer: AXObserver?
    private let events: @MainActor (AXApp, Event) -> Void

    init(_ app: NSRunningApplication, events: @escaping @MainActor (AXApp, Event) -> Void) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        element = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "hyperspace.ax.\(pid)", qos: .userInitiated)
        self.events = events
        AXUIElementSetMessagingTimeout(element, AXApp.timeout)
    }

    // MARK: - Observation

    /// Starts observing and reads the app's current windows (on the app's queue).
    func start(_ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        queue.async { [self] in
            var observer: AXObserver?
            guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
            self.observer = observer
            for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(observer, element, notification as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            let records = windows().compactMap { record($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(records) } }
        }
    }

    func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    /// Reads a window and subscribes to its own notifications. App queue only.
    func record(_ window: AXUIElement) -> WindowRecord? {
        guard let id = AX.windowID(window), AX.string(window, kAXRoleAttribute) == kAXWindowRole,
              AX.bool(window, kAXMinimizedAttribute) != true,
              let floating = AXApp.classify(window, bundleID: bundleID) else { return nil }
        AXUIElementSetMessagingTimeout(window, AXApp.timeout)
        if let observer {
            // The window id rides along as the refcon: destroyed elements can't be queried.
            let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
            for notification in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                                 kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, window, notification as CFString, refcon)
            }
        }
        return WindowRecord(id: id, element: window, floating: floating, frame: AX.frame(window),
                            title: AX.string(window, kAXTitleAttribute) ?? "", hasTabs: AXApp.hasTabBar(window))
    }

    /// Whether a new window is a native tab of one of `groups` (same app): it sits on the
    /// group's frame and either window shows a tab bar. The tab bar and the final frame can
    /// arrive a moment after the window, so this looks a few times over ~200 ms. App queue only.
    static func tabGroup(of window: AXUIElement, among groups: [(WindowID, AXUIElement, CGRect)]) -> WindowID? {
        guard !groups.isEmpty else { return nil }
        for attempt in 0..<5 {
            if attempt > 0 { usleep(50_000) }
            guard let frame = AX.frame(window) else { continue }
            for (id, element, groupFrame) in groups where groupFrame.isClose(to: frame) {
                if hasTabBar(window) || hasTabBar(element) { return id }
            }
        }
        return nil
    }

    static func hasTabBar(_ window: AXUIElement) -> Bool {
        let children: [AXUIElement] = AX.value(window, kAXChildrenAttribute) ?? []
        return children.contains { AX.string($0, kAXRoleAttribute) == kAXTabGroupRole }
    }

    func windows() -> [AXUIElement] {
        AX.value(element, kAXWindowsAttribute) as [AXUIElement]? ?? []
    }

    @MainActor
    fileprivate func received(_ element: AXUIElement, _ notification: String, _ refcon: UnsafeMutableRawPointer?) {
        let id = WindowID(UInt(bitPattern: refcon))
        let event: Event? = switch notification {
        case kAXWindowCreatedNotification: .windowCreated(element)
        case kAXFocusedWindowChangedNotification: .focusChanged
        case kAXUIElementDestroyedNotification where id != 0: .windowDestroyed(id)
        case kAXWindowMiniaturizedNotification where id != 0: .minimized(id, true)
        case kAXWindowDeminiaturizedNotification where id != 0: .minimized(id, false)
        case kAXWindowMovedNotification where id != 0, kAXWindowResizedNotification where id != 0: .moved(id)
        case kAXTitleChangedNotification where id != 0: .titleChanged(id) // read on the app's queue, not here
        default: nil
        }
        if let event { events(self, event) }
    }

    // MARK: - Classification

    /// `nil`: not a window to manage (popups, panels...). `true`: float it. `false`: tile it.
    ///
    /// Like AeroSpace: standard windows with a usable full screen button are tiled; dialogs
    /// and windows without one (settings panes, calculators, alerts) float. Some apps that
    /// hide their title bar have no such button and are tiled anyway.
    static func classify(_ window: AXUIElement, bundleID: String?) -> Bool? {
        let subrole = AX.string(window, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
        if subrole == kAXDialogSubrole { return true }
        if let id = bundleID, tiledWithoutFullscreenButton.contains(where: { id.hasPrefix($0) }) { return false }
        let button: AXUIElement? = AX.value(window, kAXFullScreenButtonAttribute)
        return !(button.flatMap { AX.bool($0, kAXEnabledAttribute) } ?? false)
    }

    private static let tiledWithoutFullscreenButton = [
        "com.microsoft.VSCode", "com.google.Chrome", "com.apple.ActivityMonitor", "org.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "com.googlecode.iterm2", "org.gnu.Emacs", "com.mitchellh.ghostty", "com.valvesoftware.steam",
    ]
}

/// App notifications carry no refcon; window notifications carry the window id. The app
/// is found by the element's pid.
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    AXApp.dispatch(element, notification as String, refcon)
}

extension AXApp {
    /// Live apps by pid, for the C callback. Main thread only.
    @MainActor static var live: [pid_t: AXApp] = [:]

    fileprivate static func dispatch(_ element: AXUIElement, _ notification: String, _ refcon: UnsafeMutableRawPointer?) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // Observer sources are on the main run loop: this is the main thread.
        nonisolated(unsafe) let element = element, refcon = refcon
        MainActor.assumeIsolated {
            guard let app = live[pid] else { return }
            app.received(element, notification, refcon)
        }
    }
}
