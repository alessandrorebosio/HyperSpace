import AppKit
import ApplicationServices
import HyperSpaceCore
import Synchronization

/// One running app driven through Accessibility. Every AX call to the app runs on the
/// app's own serial queue, so apps are driven concurrently and a slow or frozen app only
/// delays itself (calls also time out after `timeout`). Notifications arrive on the main
/// run loop; what they need read is read on the queue before the event goes out.
final class AXApp: WindowApp, @unchecked Sendable {
    /// Seconds an AX call may take before the app counts as unresponsive.
    static let timeout: Float = 1

    let pid: pid_t
    let bundleID: String?
    let name: String
    let element: AXUIElement
    let queue: DispatchQueue
    /// Per window, how many frames were requested: a queued frame older than the latest is
    /// skipped. Shared by the main thread (requests) and the queue (applies).
    private let generations = Mutex<[WindowID: Int]>([:])
    /// App queue only.
    private var observer: AXObserver?
    private var elements: [WindowID: AXUIElement] = [:]
    /// Windows that aren't to be managed, so `windows(_:)` doesn't read them every time.
    private var ignored: Set<WindowID> = []
    /// Whether the app has "enhanced UI" on, read at most every few seconds: one call less
    /// to a busy app on every layout change.
    private var enhancedUI: (on: Bool, at: DispatchTime)?
    private var stopped = false
    /// The app's own notifications are on, and its windows were first read.
    private var subscribed = false
    private var started = false
    /// Main thread only.
    nonisolated(unsafe) private var events: (@MainActor (WindowEvent) -> Void)?

    init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        name = app.localizedName ?? ""
        element = AXUIElementCreateApplication(pid)
        queue = DispatchQueue(label: "hyperspace.ax.\(pid)", qos: .userInitiated)
        AXUIElementSetMessagingTimeout(element, AXApp.timeout)
    }

    // MARK: - Observation

    func start(events: @escaping @MainActor (WindowEvent) -> Void, _ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        self.events = events
        MainActor.assumeIsolated { AXApp.live[pid] = self }
        queue.async { [self] in subscribe(attempt: 0, completion) }
    }

    /// An app that just launched may not answer Accessibility yet: subscribing is tried
    /// again, without blocking the queue, for up to a second. Past that the windows are
    /// read anyway (startup waits for every app) and `windows(_:)` tries again later.
    private func subscribe(attempt: Int, _ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        guard !stopped else { return }
        if !subscribeApp(), attempt < 10 {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in subscribe(attempt: attempt + 1, completion) }
            return
        }
        started = true
        let windows: [AXUIElement] = AX.value(element, kAXWindowsAttribute) ?? []
        let records = windows.compactMap { record($0) }
        onMain { completion(records) }
    }

    /// Creates the observer and subscribes to the app's own notifications. App queue only.
    private func subscribeApp() -> Bool {
        if subscribed { return true }
        if observer == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return false }
            self.observer = observer
            // Common modes: notifications keep coming while a menu is open or a drag tracks.
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        guard let observer else { return false }
        subscribed = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification].allSatisfy { notification in
            [.success, .notificationAlreadyRegistered].contains(AXObserverAddNotification(observer, element, notification as CFString, nil))
        }
        return subscribed
    }

    /// Windows the app has that weren't reported yet: notifications can be missed (an app
    /// slow to subscribe, a window not ready when it was created, one minimized at startup
    /// and brought back). Known windows cost one call each; subscribing is tried again.
    func windows(_ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        queue.async { [self] in
            guard started, !stopped else { return }
            _ = subscribeApp()
            let windows: [AXUIElement] = AX.value(element, kAXWindowsAttribute) ?? []
            let records = windows.compactMap { window in
                AX.windowID(window).map { elements[$0] != nil || ignored.contains($0) } == true ? nil : record(window)
            }
            onMain { completion(records) }
        }
    }

    func stop() {
        events = nil
        MainActor.assumeIsolated { if AXApp.live[pid] === self { AXApp.live[pid] = nil } }
        queue.async { [self] in
            stopped = true
            if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
            observer = nil
        }
    }

    /// Reads a window and subscribes to its own notifications. App queue only.
    private func record(_ window: AXUIElement) -> WindowRecord? {
        guard let id = AX.windowID(window), !ignored.contains(id), AX.bool(window, kAXMinimizedAttribute) != true else { return nil }
        // Not a window to manage (helper windows, popups): never read again.
        guard AX.string(window, kAXRoleAttribute) == kAXWindowRole, let floating = AXApp.classify(window, bundleID: bundleID) else {
            ignored.insert(id)
            return nil
        }
        AXUIElementSetMessagingTimeout(window, AXApp.timeout)
        elements[id] = window
        if let observer {
            // The window id rides along as the refcon: destroyed elements can't be queried.
            let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
            for notification in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                                 kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, window, notification as CFString, refcon)
            }
        }
        return WindowRecord(id: id, floating: floating, frame: AX.frame(window), title: AX.string(window, kAXTitleAttribute) ?? "")
    }

    @MainActor
    fileprivate func received(_ element: AXUIElement, _ notification: String, _ refcon: UnsafeMutableRawPointer?) {
        guard let events else { return }
        let id = WindowID(UInt(bitPattern: refcon))
        switch notification {
        case kAXWindowCreatedNotification:
            nonisolated(unsafe) let element = element
            queue.async { [self] in created(element, attempt: 0) }
        case kAXFocusedWindowChangedNotification:
            events(.focusChanged)
        case kAXUIElementDestroyedNotification where id != 0:
            queue.async { [self] in elements[id] = nil }
            events(.destroyed(id))
        case kAXWindowMiniaturizedNotification where id != 0:
            events(.minimized(id, true))
        case kAXWindowDeminiaturizedNotification where id != 0:
            events(.minimized(id, false))
        case kAXWindowMovedNotification where id != 0, kAXWindowResizedNotification where id != 0:
            events(.moved(id))
        case kAXTitleChangedNotification where id != 0:
            queue.async { [self] in
                let title = elements[id].flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
                onMain { [weak self] in self?.events?(.titleChanged(id, title)) }
            }
        default:
            break
        }
    }

    /// The read is answered on the app's main thread, so by the time it returns the app is
    /// done creating the window (and a new tab has hidden the previous one). Some apps
    /// announce a window before it has its role or id: it's read again a few times.
    private func created(_ element: AXUIElement, attempt: Int) {
        guard !stopped else { return }
        guard let record = record(element) else {
            guard attempt < 3, AX.string(element, kAXRoleAttribute) != kAXMenuRole else { return }
            nonisolated(unsafe) let element = element
            queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in created(element, attempt: attempt + 1) }
            return
        }
        onMain { [weak self] in self?.events?(.created(record)) }
    }

    // MARK: - Driving windows

    func focusedWindow(_ completion: @escaping @MainActor (WindowID?) -> Void) {
        queue.async { [self] in
            let window: AXUIElement? = AX.value(element, kAXFocusedWindowAttribute) ?? AX.value(element, kAXMainWindowAttribute)
            let id = window.flatMap(AX.windowID)
            onMain { completion(id) }
        }
    }

    func frame(of window: WindowID, _ completion: @escaping @MainActor (CGRect?) -> Void) {
        queue.async { [self] in
            let frame = elements[window].flatMap(AX.frame)
            onMain { completion(frame) }
        }
    }

    func setFrames(_ changes: [(window: WindowID, frame: CGRect, old: CGRect?)]) {
        let generation = generations.withLock { generations in
            changes.map { change in
                generations[change.window, default: 0] += 1
                return generations[change.window]!
            }
        }
        queue.async { [self] in
            // Accessibility clients like VoiceOver or Grammarly turn on "enhanced UI", which
            // animates every frame change: off while we move windows, like AeroSpace does.
            if enhancedUI.map({ DispatchTime.now().uptimeNanoseconds - $0.at.uptimeNanoseconds > 5_000_000_000 }) ?? true {
                enhancedUI = (AX.bool(element, "AXEnhancedUserInterface") == true, .now())
            }
            let enhanced = enhancedUI?.on == true
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            for (i, change) in changes.enumerated() {
                guard generations.withLock({ $0[change.window] }) == generation[i], let window = elements[change.window] else { continue }
                AX.setFrame(window, change.frame, old: change.old)
            }
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
    }

    func focus(_ window: WindowID) {
        queue.async { [self] in
            guard let window = elements[window] else { return }
            // Raise first, so the window is on top by the time the app is active. The app is
            // made frontmost through AX: NSRunningApplication.activate() from a background
            // app can be refused by macOS 14+ cooperative activation.
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AX.raise(window)
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    func close(_ window: WindowID) {
        queue.async { [self] in elements[window].map(AX.close) }
    }

    func minimize(_ window: WindowID) {
        queue.async { [self] in
            guard let window = elements[window] else { return }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func setFullscreen(_ window: WindowID, _ on: Bool?) {
        queue.async { [self] in
            guard let window = elements[window] else { return }
            let wanted = on ?? !(AX.bool(window, "AXFullScreen") ?? false)
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, wanted as CFBoolean)
        }
    }

    func pressNewWindow(_ completion: @escaping @MainActor (Bool) -> Void) {
        queue.async { [self] in
            let bar: AXUIElement? = AX.value(element, kAXMenuBarAttribute)
            let item = bar.flatMap { AXApp.menuItem(in: $0, key: "N", depth: 0) }
            let pressed = item.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false
            onMain { completion(pressed) }
        }
    }

    /// The enabled menu item under `element` whose shortcut is ⌘ and `key` alone, menus
    /// first, then their submenus (Terminal's ⌘N is in Shell > New Window). App queue only.
    private static func menuItem(in element: AXUIElement, key: String, depth: Int) -> AXUIElement? {
        let children: [AXUIElement] = AX.value(element, kAXChildrenAttribute) ?? []
        for child in children where AX.string(child, kAXMenuItemCmdCharAttribute) == key {
            // No modifier flags means ⌘ alone.
            if (AX.value(child, kAXMenuItemCmdModifiersAttribute) as Int?) == 0, AX.bool(child, kAXEnabledAttribute) == true { return child }
        }
        guard depth < 4 else { return nil } // bar, bar item, menu, item, submenu
        for child in children {
            if let found = menuItem(in: child, key: key, depth: depth + 1) { return found }
        }
        return nil
    }

    func terminate() {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    private func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    // MARK: - Classification

    /// `nil`: not a window to manage. `true`: float it. `false`: tile it. The rule is
    /// `WMWindowKind`'s; this reads what it needs, and for standard windows only.
    static func classify(_ window: AXUIElement, bundleID: String?) -> Bool? {
        let subrole = AX.string(window, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole else {
            return WMWindowKind.floating(subrole: subrole, resizable: false, fullscreenButton: false, bundleID: bundleID)
        }
        // A window that doesn't answer counts as resizable: tiling is the default.
        var resizable: DarwinBoolean = true
        if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) != .success { resizable = true }
        let button: AXUIElement? = AX.value(window, kAXFullScreenButtonAttribute)
        return WMWindowKind.floating(subrole: subrole, resizable: resizable.boolValue,
                                     fullscreenButton: button.flatMap { AX.bool($0, kAXEnabledAttribute) } ?? false, bundleID: bundleID)
    }
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
