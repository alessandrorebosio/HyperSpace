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
        MainActor.assumeIsolated { completion(initial) }
    }

    func stop() { events = nil }

    func focusedWindow(_ completion: @escaping @MainActor (WindowID?) -> Void) {
        MainActor.assumeIsolated { completion(focused) }
    }

    func frame(of window: WindowID, _ completion: @escaping @MainActor (CGRect?) -> Void) {
        MainActor.assumeIsolated { completion(frames[window]) }
    }

    func setFrames(_ changes: [(window: WindowID, frame: CGRect, old: CGRect?)]) {
        for change in changes { frames[change.window] = change.frame }
    }

    func focus(_ window: WindowID) { raised.append(window) }
    func close(_ window: WindowID) { closed.append(window) }
    func minimize(_ window: WindowID) {}
    func setFullscreen(_ window: WindowID, _ on: Bool?) {}
    func terminate() {}

    @MainActor func send(_ event: WindowEvent) { events?(event) }

    /// A new window, appearing where macOS puts it.
    @MainActor func create(_ id: WindowID, frame: CGRect, title: String = "", floating: Bool = false) {
        frames[id] = frame
        send(.created(WindowRecord(id: id, floating: floating, frame: frame, title: title)))
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
