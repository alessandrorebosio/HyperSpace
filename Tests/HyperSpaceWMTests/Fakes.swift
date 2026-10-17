import CoreGraphics
import Foundation
import HyperSpaceCore
@testable import HyperSpaceWM

/// An app whose windows live in memory: frames set by the window manager land in `frames`,
/// and tests make windows appear, close or get focus by sending events. Completions run
/// at once, on the main actor the tests run on.
final class FakeApp: WindowApp, @unchecked Sendable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    /// Windows the app has when the window manager starts watching it.
    var initial: [WindowRecord]
    /// Every window's frame on screen, and which ones are off screen (background tabs).
    var frames: [WindowID: CGRect] = [:]
    var offscreen: Set<WindowID> = []
    var focused: WindowID?
    var raised: [WindowID] = []
    var closed: [WindowID] = []
    /// Set to report the windows only on `finishStart()`, like a slow app.
    var slowStart = false
    /// Windows that ignore the next frame they're given, like a busy app past the timeout.
    var dropNextFrame: Set<WindowID> = []
    private lazy var all: [WindowRecord] = initial
    private var pendingStart: (@MainActor () -> Void)?
    private var events: (@MainActor (WindowEvent) -> Void)?

    init(pid: pid_t, bundleID: String, windows: [WindowRecord] = []) {
        self.pid = pid
        self.bundleID = bundleID
        name = bundleID
        initial = windows
        for window in windows { frames[window.id] = window.frame }
    }

    func start(events: @escaping @MainActor (WindowEvent) -> Void, _ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        self.events = events
        // Where the windows are now, as a real app reports them.
        let initial = self.initial.map { WindowRecord(id: $0.id, floating: $0.floating, frame: frames[$0.id] ?? $0.frame, title: $0.title,
                                                    fullscreen: $0.fullscreen) }
        if slowStart {
            pendingStart = { completion(initial) }
        } else {
            MainActor.assumeIsolated { completion(initial) }
        }
    }

    @MainActor func finishStart() {
        pendingStart?()
        pendingStart = nil
    }

    func stop() { events = nil }

    /// Every window the app has: the initial ones, plus created and missed ones, still open.
    func windows(_ completion: @escaping @MainActor ([WindowRecord]) -> Void) {
        let open = all.filter { frames[$0.id] != nil }
        MainActor.assumeIsolated { completion(open) }
    }

    /// A window that appears without its created event (the notification was missed).
    @MainActor func miss(_ id: WindowID, frame: CGRect) {
        frames[id] = frame
        all.append(WindowRecord(id: id, floating: false, frame: frame, title: ""))
    }

    func focusedWindow(_ completion: @escaping @MainActor (WindowID?) -> Void) {
        MainActor.assumeIsolated { completion(focused) }
    }

    func frame(of window: WindowID, _ completion: @escaping @MainActor (CGRect?) -> Void) {
        MainActor.assumeIsolated { completion(frames[window]) }
    }

    func setFrames(_ changes: [(window: WindowID, frame: CGRect, old: CGRect?)]) {
        for change in changes where dropNextFrame.remove(change.window) == nil { frames[change.window] = change.frame }
    }

    func focus(_ window: WindowID) { raised.append(window) }
    func close(_ window: WindowID) { closed.append(window) }
    func minimize(_ window: WindowID) {}
    func setFullscreen(_ window: WindowID, _ on: Bool?) {}
    /// The window the app's ⌘N menu item opens (nil: it has none), and how often it was pressed.
    var newWindow: WindowID?
    var newWindowPresses = 0
    var onPress: (@MainActor () -> Void)?
    func pressNewWindow(_ completion: @escaping @MainActor (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard let id = newWindow else { return completion(false) }
            newWindowPresses += 1
            completion(true)
            // The app comes forward first, its old window focused, as Terminal does.
            onPress?()
            create(id, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        }
    }
    func flush(_ group: DispatchGroup) {}
    func terminate() {}

    @MainActor func send(_ event: WindowEvent) { events?(event) }

    /// A new window, appearing where macOS puts it.
    @MainActor func create(_ id: WindowID, frame: CGRect, title: String = "", floating: Bool = false) {
        frames[id] = frame
        let record = WindowRecord(id: id, floating: floating, frame: frame, title: title)
        all.append(record)
        send(.created(record))
    }

    @MainActor func destroy(_ id: WindowID) {
        frames[id] = nil
        offscreen.remove(id)
        send(.destroyed(id))
    }
}

@MainActor
final class FakeSystem: WindowSystem {
    let layoutURL: URL
    var frontmost: pid_t?
    var screens: [WMMonitor]
    var apps: [pid_t: FakeApp] = [:]
    private var handler: (@MainActor (SystemEvent) -> Void)?

    init(screens: [WMMonitor], apps: [FakeApp] = []) {
        self.screens = screens
        for app in apps { self.apps[app.pid] = app }
        frontmost = apps.first?.pid
        layoutURL = FileManager.default.temporaryDirectory.appending(path: "hyperspace-tests-\(UUID().uuidString)/layout.json")
    }

    func monitors() -> [WMMonitor] { screens }

    /// The input each display shows (DDC), by display id; read at once.
    var inputs: [UInt32: UInt8] = [:]
    func monitorInputs(_ ids: [UInt32], _ completion: @escaping @MainActor ([UInt32: UInt8]) -> Void) {
        completion(inputs.filter { ids.contains($0.key) })
    }

    /// Settings asked of displays over DDC, in order.
    var settings: [(id: UInt32, setting: WMCommand.MonitorSetting)] = []
    func setMonitor(_ id: UInt32, _ setting: WMCommand.MonitorSetting) { settings.append((id, setting)) }

    func windowServer(_ ids: [WindowID]) -> [WindowID: (bounds: CGRect, onscreen: Bool)] {
        var result: [WindowID: (bounds: CGRect, onscreen: Bool)] = [:]
        for app in apps.values {
            for id in ids {
                if let frame = app.frames[id] { result[id] = (frame, !app.offscreen.contains(id)) }
            }
        }
        return result
    }

    func runningApps() -> [(pid: pid_t, bundleID: String?, name: String)] {
        apps.values.sorted { $0.pid < $1.pid }.map { ($0.pid, $0.bundleID, $0.name) }
    }

    func app(_ pid: pid_t) -> WindowApp? { apps[pid] }
    func isHidden(_ pid: pid_t) -> Bool { false }
    func unhide(_ pid: pid_t) {}
    /// Bundle ids `open` was asked for.
    var opened: [String] = []
    func open(bundleID: String) -> Bool {
        opened.append(bundleID)
        return true
    }
    /// Bundle ids of apps uninstalled.
    var uninstalled: Set<String> = []
    func isInstalled(bundleID: String) -> Bool { !uninstalled.contains(bundleID) }
    func observe(_ handler: @escaping @MainActor (SystemEvent) -> Void) { self.handler = handler }
    func stopObserving() { handler = nil }

    func send(_ event: SystemEvent) { handler?(event) }
}

extension WindowManager {
    /// A window manager on a fake system, with handlers that do nothing.
    static func fake(_ system: FakeSystem) -> WindowManager {
        WindowManager(handlers: Handlers(reloadConfig: {}, enable: { _ in }, modeChanged: { _ in }, mediaKey: { _ in }, changed: {}),
                      system: system)
    }
}
