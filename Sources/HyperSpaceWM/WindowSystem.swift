import AppKit
import HyperSpaceCore

/// What the window manager needs to know about a window, read once when it appears.
struct WindowRecord: Sendable, Equatable {
    let id: WindowID
    let floating: Bool
    let frame: CGRect?
    /// Kept up to date through title events, for rules and `list-windows`.
    var title: String
}

/// What an app reports about its windows, already read: the window manager never waits
/// on an app.
enum WindowEvent: Sendable {
    case created(WindowRecord)
    case destroyed(WindowID)
    case focusChanged
    case minimized(WindowID, Bool)
    case moved(WindowID)
    case titleChanged(WindowID, String)
}

/// A running app's windows as the window manager drives them, by window id. `AXApp` does it
/// through Accessibility; the tests use a fake. Called on the main thread; completions and
/// events arrive there too.
protocol WindowApp: AnyObject, Sendable {
    var pid: pid_t { get }
    var bundleID: String? { get }
    var name: String { get }
    /// Starts reporting `events` and reads the windows the app already has.
    func start(events: @escaping @MainActor (WindowEvent) -> Void, _ completion: @escaping @MainActor ([WindowRecord]) -> Void)
    func stop()
    /// Windows the app has that it hasn't reported (their events were missed), read now.
    func windows(_ completion: @escaping @MainActor ([WindowRecord]) -> Void)
    /// The focused window, or the main one for apps that don't report focus.
    func focusedWindow(_ completion: @escaping @MainActor (WindowID?) -> Void)
    func frame(of window: WindowID, _ completion: @escaping @MainActor (CGRect?) -> Void)
    /// Frames to set, with the frame each window has now (only what differs is set). A frame
    /// superseded by a newer one before it's applied is skipped.
    func setFrames(_ changes: [(window: WindowID, frame: CGRect, old: CGRect?)])
    /// Raises the window and makes the app frontmost, as a click would.
    func focus(_ window: WindowID)
    func close(_ window: WindowID)
    func minimize(_ window: WindowID)
    func setFullscreen(_ window: WindowID, _ on: Bool?)
    /// Presses the app's menu item with the ⌘N shortcut (New Window, New Document...):
    /// false if it has no such item enabled.
    func pressNewWindow(_ completion: @escaping @MainActor (Bool) -> Void)
    /// Leaves `group` once what was asked of the app so far is done.
    func flush(_ group: DispatchGroup)
    func terminate()
}

enum SystemEvent: Sendable {
    case launched(pid_t)
    case terminated(pid_t)
    case activated(pid_t)
    case hidden(pid_t, Bool)
    /// Displays connected, disconnected or woken up.
    case displaysChanged
}

/// The rest of macOS the window manager uses: apps, displays, the window server.
@MainActor
protocol WindowSystem: AnyObject {
    /// Where the layout is saved across restarts.
    var layoutURL: URL { get }
    var frontmost: pid_t? { get }
    /// Displays in AX coordinates: origin at the top left of the main display, y down.
    func monitors() -> [WMMonitor]
    /// The input source each of these displays shows (DDC), read off the main thread; the
    /// ones that don't answer are left out.
    func monitorInputs(_ ids: [UInt32], _ completion: @escaping @MainActor ([UInt32: UInt8]) -> Void)
    /// Changes a display's setting over DDC, off the main thread.
    func setMonitor(_ id: UInt32, _ setting: WMCommand.MonitorSetting)
    /// Bounds and visibility of windows, from the window server (no IPC to their apps).
    func windowServer(_ ids: [WindowID]) -> [WindowID: (bounds: CGRect, onscreen: Bool)]
    /// Regular apps running now.
    func runningApps() -> [(pid: pid_t, bundleID: String?, name: String)]
    /// The app behind `pid` if it's a regular app (one with windows to manage).
    func app(_ pid: pid_t) -> WindowApp?
    func isHidden(_ pid: pid_t) -> Bool
    func unhide(_ pid: pid_t)
    /// Launches the app, or activates it if it runs (one without windows then opens one).
    /// False if no app has that bundle id.
    func open(bundleID: String) -> Bool
    func observe(_ handler: @escaping @MainActor (SystemEvent) -> Void)
    func stopObserving()
}

/// The real system: NSWorkspace, NSScreen, CGWindowList and Accessibility.
@MainActor
final class MacSystem: WindowSystem {
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private let ddc = DDC.shared

    init() {
        // One timeout for every AX call: a frozen app answers nothing for 6 s by default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXApp.timeout)
    }

    /// `~/Library/Application Support/HyperSpace/layout.json`, next to the IPC socket.
    let layoutURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/HyperSpace/layout.json")

    var frontmost: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func monitors() -> [WMMonitor] {
        guard let main = NSScreen.screens.first else { return [] }
        func ax(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).flatMap { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String? }
            return WMMonitor(id: id, name: screen.localizedName, key: uuid, isMain: screen == main,
                             frame: ax(screen.frame), visible: ax(screen.visibleFrame))
        }
    }

    /// A read still going (a slow display) isn't queued behind by another.
    private var readingInputs = false

    func monitorInputs(_ ids: [UInt32], _ completion: @escaping @MainActor ([UInt32: UInt8]) -> Void) {
        guard !readingInputs else { return }
        readingInputs = true
        ddc.inputs(of: ids) { [weak self] inputs in
            self?.readingInputs = false
            completion(inputs)
        }
    }

    func setMonitor(_ id: UInt32, _ setting: WMCommand.MonitorSetting) {
        ddc.set(setting, on: id) { ok in
            if !ok { HyperSpace.logger("wm").error("display \(id) didn't take \(String(describing: setting)) (no DDC?)") }
        }
    }

    func windowServer(_ ids: [WindowID]) -> [WindowID: (bounds: CGRect, onscreen: Bool)] {
        WindowServer.windows(ids)
    }

    func runningApps() -> [(pid: pid_t, bundleID: String?, name: String)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            ($0.processIdentifier, $0.bundleIdentifier, $0.localizedName ?? "")
        }
    }

    func app(_ pid: pid_t) -> WindowApp? {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              let running = NSRunningApplication(processIdentifier: pid), running.activationPolicy == .regular else { return nil }
        return AXApp(running)
    }

    func isHidden(_ pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid)?.isHidden ?? false }

    func unhide(_ pid: pid_t) { NSRunningApplication(processIdentifier: pid)?.unhide() }

    func open(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    func observe(_ handler: @escaping @MainActor (SystemEvent) -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ event: @escaping @Sendable (pid_t) -> SystemEvent) {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { handler(event(pid)) }
            }))
        }
        on(NSWorkspace.didLaunchApplicationNotification) { .launched($0) }
        on(NSWorkspace.didTerminateApplicationNotification) { .terminated($0) }
        on(NSWorkspace.didActivateApplicationNotification) { .activated($0) }
        on(NSWorkspace.didHideApplicationNotification) { .hidden($0, true) }
        on(NSWorkspace.didUnhideApplicationNotification) { .hidden($0, false) }
        for (center, name) in [(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
                               (workspace, NSWorkspace.didWakeNotification)] {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(.displaysChanged) }
            }))
        }
    }

    func stopObserving() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }
}
