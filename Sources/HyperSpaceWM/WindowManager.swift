import AppKit
@preconcurrency import ApplicationServices
import HyperSpaceCore
import Synchronization

/// The tiling window manager: AeroSpace's model (`WMModel`) driven by Accessibility.
///
/// How it stays fast:
/// - **Event-driven state.** Windows are read once when they appear and then followed
///   through AX notifications; no command or notification re-reads every app's windows.
/// - **Diffs only.** `apply()` compares the layout with the frames already set and touches
///   only windows that change, and per window only the attribute that changes.
/// - **Concurrent apps.** Each app has its own AX queue (`AXApp`), so frames are set in
///   parallel and a frozen app can't stall the others; superseded frames are skipped.
/// - **Off the input thread.** Hotkeys arrive as commands; the tap never waits for AX.
@MainActor
public final class WindowManager {
    public struct Handlers {
        public var exec: (String) -> Void
        public var reloadConfig: () -> Void
        public var enable: (Bool?) -> Void
        /// The focused workspace changed (for the menu bar).
        public var changed: () -> Void

        public init(exec: @escaping (String) -> Void, reloadConfig: @escaping () -> Void,
                    enable: @escaping (Bool?) -> Void, changed: @escaping () -> Void) {
            self.exec = exec
            self.reloadConfig = reloadConfig
            self.enable = enable
            self.changed = changed
        }
    }

    private let log = HyperSpace.logger("wm")
    private let handlers: Handlers
    private var model: WMModel?
    private var settings = WMSettings()
    private var observers: [any NSObjectProtocol] = []

    /// Every window seen, managed or not right now (minimized, hidden app).
    private var records: [WindowID: (app: AXApp, record: WindowRecord)] = [:]
    /// The frame each window has on screen as far as we know: set by us or read.
    private var frames: [WindowID: CGRect] = [:]
    /// The frame we last asked for: layouts are diffed against it, so a window that can't
    /// take a frame (minimum size) isn't asked again on every change.
    private var targets: [WindowID: CGRect] = [:]
    /// When we last set each window's frame: its own move notifications follow shortly.
    private var setAt: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows parked off-screen, with the frame to give back to floating ones.
    private var parked: [WindowID: CGRect] = [:]
    /// Pending "a tiled window was dragged" checks.
    private var snapChecks: [WindowID: Task<Void, Never>] = [:]

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public var isRunning: Bool { model != nil }
    public var focusedWorkspace: String? { model?.focusedWorkspace.name }

    // MARK: - Lifecycle

    public func start(_ settings: WMSettings) {
        self.settings = settings
        if let model {
            model.settings = settings
            apply()
            return
        }
        // One timeout for every AX call: a frozen app answers nothing for 6 s by default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXApp.timeout)
        model = WMModel(monitors: WindowManager.monitors(), settings: settings)
        observe()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { watch(app) }
        log.info("window manager started")
        handlers.changed()
    }

    /// Gives every window back: parked ones return on screen, nothing stays managed.
    public func stop() {
        guard model != nil else { return }
        for (id, frame) in parked {
            guard let (app, record) = records[id] else { continue }
            nonisolated(unsafe) let element = record.element
            app.queue.async { AX.setPosition(element, frame.origin) }
        }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        for app in AXApp.live.values { app.stop() }
        AXApp.live = [:]
        snapChecks.values.forEach { $0.cancel() }
        snapChecks = [:]
        records = [:]
        frames = [:]
        targets = [:]
        setAt = [:]
        parked = [:]
        model = nil
        log.info("window manager stopped")
        handlers.changed()
    }

    /// Runs a command, e.g. from a hotkey or `hsctl`. Returns an error message for the user.
    @discardableResult
    public func run(_ text: String) -> String? {
        guard let model else { return "the window manager is off (wm.toml: enabled = true)" }
        do {
            let command = try WMCommand(parsing: text)
            let focusedBefore = model.focused
            let workspaceBefore = model.focusedWorkspace.name
            switch try model.run(command) {
            case .none: break
            case let .close(id): close(id)
            case let .exec(shell): handlers.exec(shell)
            case .reloadConfig: handlers.reloadConfig()
            case let .enable(on): handlers.enable(on)
            }
            apply()
            if model.focused != focusedBefore || model.focusedWorkspace.name != workspaceBefore { focusNative() }
            if model.focusedWorkspace.name != workspaceBefore { handlers.changed() }
            return nil
        } catch {
            return error.message
        }
    }

    /// `hsctl list-workspaces`-style summary.
    public var summary: String {
        guard let model else { return "window manager off" }
        return model.workspaceNames.map { name in
            let workspace = model.workspace(name)
            let shown = model.visible.values.contains(name) ? (name == model.focusedWorkspace.name ? "*" : "+") : " "
            return "\(shown) \(name)  \(workspace.windows.count) window(s)"
        }.joined(separator: "\n")
    }

    /// `hsctl list-windows`: every window seen, how it's managed, and the focused one.
    public var windowList: String {
        guard let model else { return "window manager off" }
        return records.sorted { $0.key < $1.key }.map { id, entry in
            let name = NSRunningApplication(processIdentifier: entry.app.pid)?.localizedName ?? "?"
            let state = model.windows[id].map { $0.floating ? "floating" : "tiled" } ?? "not managed"
            let workspace = model.workspace(of: id)?.name ?? "-"
            return "\(model.focused == id ? "*" : " ") \(id)  \(name)  workspace \(workspace)  \(state)"
        }.joined(separator: "\n")
    }

    // MARK: - System events

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { handler(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            if app.activationPolicy == .regular { self?.watch(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.forget(app: app.processIdentifier) }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in self?.syncFocus(app.processIdentifier) }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in self?.setHidden(app.processIdentifier, true) }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in self?.setHidden(app.processIdentifier, false) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.setMonitors(WindowManager.monitors())
                self?.apply()
            }
        })
    }

    private func watch(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        guard AXApp.live[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let app = AXApp(running) { [weak self] app, event in self?.handle(app, event) }
        AXApp.live[pid] = app
        let hidden = running.isHidden
        app.start { [weak self] records in
            guard let self, AXApp.live[pid] === app else { return }
            for record in records { self.add(record, of: app, managed: !hidden) }
            self.syncFocus(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            self.apply()
        }
    }

    private func handle(_ app: AXApp, _ event: AXApp.Event) {
        switch event {
        case let .windowCreated(element):
            nonisolated(unsafe) let element = element
            app.queue.async { [weak self] in
                guard let record = app.record(element) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.records[record.id] == nil else { return }
                        self.add(record, of: app, managed: true)
                        self.apply()
                    }
                }
            }
        case let .windowDestroyed(id):
            forget(window: id)
            apply()
        case .focusChanged:
            syncFocus(app.pid)
        case let .minimized(id, isMinimized):
            setManaged(id, !isMinimized)
            apply()
        case let .moved(id):
            moved(id)
        }
    }

    private func add(_ record: WindowRecord, of app: AXApp, managed: Bool) {
        records[record.id] = (app, record)
        frames[record.id] = record.frame
        if managed { manage(record.id) }
    }

    private func manage(_ id: WindowID) {
        guard let model, let (app, record) = records[id] else { return }
        let monitor = record.frame.flatMap { frame in
            model.monitors.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
        }
        model.add(WMWindowInfo(id: id, pid: app.pid, bundleID: app.bundleID, floating: record.floating), monitor: monitor)
    }

    private func setManaged(_ id: WindowID, _ managed: Bool) {
        if managed { manage(id) } else { model?.remove(id) }
    }

    private func forget(window id: WindowID) {
        model?.remove(id)
        records[id] = nil
        frames[id] = nil
        targets[id] = nil
        setAt[id] = nil
        parked[id] = nil
        snapChecks.removeValue(forKey: id)?.cancel()
    }

    private func forget(app pid: pid_t) {
        AXApp.live.removeValue(forKey: pid)?.stop()
        for (id, entry) in records where entry.app.pid == pid { forget(window: id) }
        apply()
    }

    private func setHidden(_ pid: pid_t, _ hidden: Bool) {
        for (id, entry) in records where entry.app.pid == pid { setManaged(id, !hidden) }
        apply()
    }

    /// macOS focus moved: follow it (and show its workspace if it was hidden).
    private func syncFocus(_ pid: pid_t?) {
        guard let pid, let app = AXApp.live[pid] else { return }
        app.queue.async { [weak self] in
            // Some apps (Electron ones, mostly) don't always report a focused window: fall
            // back to their main window.
            let window: AXUIElement? = AX.value(app.element, kAXFocusedWindowAttribute) ?? AX.value(app.element, kAXMainWindowAttribute)
            let id = window.flatMap(AX.windowID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let model = self.model else { return }
                    let workspace = model.focusedWorkspace.name
                    // Still nothing we manage: the app's most recently focused window will do.
                    let known = id.flatMap { model.windows[$0] != nil ? $0 : nil }
                        ?? self.records.filter { $0.value.app.pid == pid && model.windows[$0.key] != nil }.map(\.key).min()
                    self.log.debug("focus: pid \(pid) window \(id.map(String.init) ?? "none") -> \(known.map(String.init) ?? "none")")
                    if model.nativeFocus(known) { self.apply() }
                    if model.focusedWorkspace.name != workspace { self.handlers.changed() }
                }
            }
        }
    }

    /// A window moved or resized. Floating: remember its frame. Tiled: if the user dragged
    /// it, put it back once the drag is over (our own moves match the known frame).
    private func moved(_ id: WindowID) {
        guard parked[id] == nil, let (app, record) = records[id] else { return }
        snapChecks.removeValue(forKey: id)?.cancel()
        snapChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            nonisolated(unsafe) let element = record.element
            app.queue.async {
                let frame = AX.frame(element)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let frame, self.parked[id] == nil else { return }
                        self.snapChecks[id] = nil
                        self.frames[id] = frame
                        // Right after our own change it's the app settling (e.g. a minimum size).
                        let ours = self.setAt[id].map { ContinuousClock.now - $0 < .seconds(1) } ?? false
                        guard !ours, let target = self.targets[id], !target.isClose(to: frame),
                              self.model?.windows[id]?.floating == false else { return }
                        self.targets[id] = nil // dragged by the user: put it back
                        self.apply()
                    }
                }
            }
        }
    }

    // MARK: - Applying the model

    /// Puts every window where the model says, touching only what changed.
    private func apply() {
        guard let model else { return }
        let layout = model.layout()
        var batches: [pid_t: (AXApp, [(AXUIElement, WindowID, CGRect, CGRect?)])] = [:]
        let now = ContinuousClock.now
        func set(_ id: WindowID, _ frame: CGRect) {
            guard let (app, record) = records[id] else { return }
            guard targets[id].map({ !$0.isClose(to: frame) }) ?? true else { return }
            let old = frames[id]
            frames[id] = frame
            targets[id] = frame
            setAt[id] = now
            batches[app.pid, default: (app, [])].1.append((record.element, id, frame, old))
        }
        // Show first, then hide: less flicker when switching workspaces.
        for (id, frame) in layout.tiled {
            parked[id] = nil
            set(id, frame)
        }
        for (id, _) in layout.floating {
            if let frame = parked.removeValue(forKey: id) { set(id, frame) }
        }
        for (id, monitorID) in layout.hidden where parked[id] == nil {
            guard let monitor = model.monitors.first(where: { $0.id == monitorID }), let frame = frames[id] else { continue }
            parked[id] = frame
            // Bottom right corner, one point inside so macOS doesn't pull the window back.
            set(id, CGRect(origin: CGPoint(x: monitor.visible.maxX - 1, y: monitor.visible.maxY - 1), size: frame.size))
        }
        for (_, (app, changes)) in batches { app.setFrames(changes) }
    }

    /// Raises and focuses the model's focused window, as macOS would on a click.
    private func focusNative() {
        guard let id = model?.focused, let (app, record) = records[id] else { return }
        nonisolated(unsafe) let element = record.element
        app.queue.async {
            // Raise first, so the window is on top by the time the app is active. The app is
            // made frontmost through AX: NSRunningApplication.activate() from a background
            // app can be refused by macOS 14+ cooperative activation.
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AX.raise(element)
            AXUIElementSetAttributeValue(app.element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func close(_ id: WindowID) {
        guard let (app, record) = records[id] else { return }
        nonisolated(unsafe) let element = record.element
        app.queue.async { AX.close(element) }
    }

    /// Displays in AX coordinates: origin at the top left of the main display, y down.
    static func monitors() -> [WMMonitor] {
        guard let main = NSScreen.screens.first else { return [] }
        func ax(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return WMMonitor(id: id, frame: ax(screen.frame), visible: ax(screen.visibleFrame))
        }
    }
}

extension AXApp {
    /// Applies a batch of frames on the app's queue. A frame superseded by a newer one
    /// (fast repeated commands) is skipped instead of applied and then undone.
    func setFrames(_ changes: [(AXUIElement, WindowID, CGRect, CGRect?)]) {
        let generation = generations.withLock { generations in
            changes.map { change in
                generations[change.1, default: 0] += 1
                return generations[change.1]!
            }
        }
        nonisolated(unsafe) let changes = changes
        queue.async { [self] in
            // Accessibility clients like VoiceOver or Grammarly turn on "enhanced UI", which
            // animates every frame change: off while we move windows, like AeroSpace does.
            let enhanced = AX.bool(element, "AXEnhancedUserInterface") == true
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            for (i, (window, id, frame, old)) in changes.enumerated() {
                guard generations.withLock({ $0[id] }) == generation[i] else { continue }
                AX.setFrame(window, frame, old: old)
            }
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
    }
}

extension CGRect {
    /// Equal within a point: apps round frames their own way.
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
