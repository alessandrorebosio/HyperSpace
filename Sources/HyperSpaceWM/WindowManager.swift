import AppKit
import HyperSpaceCore

/// The tiling window manager: AeroSpace's model (`WMModel`), config and commands, driven by
/// Accessibility. This file holds its state, start and stop, and how the model reaches the
/// screen; the rest is split by topic (`+Windows`, `+Tabs`, `+Commands`, `+Queries`,
/// `+SavedLayout`). Apps and the system are reached through `WindowApp` and `WindowSystem`,
/// so the service runs against fakes in tests.
///
/// How it stays fast:
/// - **Event-driven state.** Windows are read once when they appear and then followed
///   through AX notifications; no command or notification re-reads every app's windows.
/// - **Diffs only.** `apply()` compares the layout with the frames already requested and
///   touches only windows that change, and per window only the attribute that changes.
/// - **Concurrent apps.** Each app has its own AX queue (`AXApp`), so frames are set in
///   parallel and a frozen app can't stall the others; superseded frames are skipped.
/// - **Off the input thread.** Hotkeys arrive as commands; the tap never waits for AX.
@MainActor
public final class WindowManager {
    public struct Handlers {
        public var reloadConfig: () -> Void
        public var enable: (Bool?) -> Void
        /// The binding mode changed: the tap must use that mode's hotkeys.
        public var modeChanged: (String) -> Void
        /// A media key (`volume up`...), sent like the keyboard's.
        public var mediaKey: (SystemAction) -> Void
        /// The focused workspace changed (for the menu bar).
        public var changed: () -> Void

        public init(reloadConfig: @escaping () -> Void, enable: @escaping (Bool?) -> Void,
                    modeChanged: @escaping (String) -> Void, mediaKey: @escaping (SystemAction) -> Void,
                    changed: @escaping () -> Void) {
            self.reloadConfig = reloadConfig
            self.enable = enable
            self.modeChanged = modeChanged
            self.mediaKey = mediaKey
            self.changed = changed
        }
    }

    typealias FocusState = (window: WindowID?, workspace: String, monitor: UInt32)

    let log = HyperSpace.logger("wm")
    let handlers: Handlers
    let system: WindowSystem
    var model: WMModel?
    var settings = WMSettings()
    public internal(set) var mode = "main"

    var apps: [pid_t: WindowApp] = [:]
    /// Every window seen, managed or not right now (minimized, hidden app).
    var records: [WindowID: (app: WindowApp, record: WindowRecord)] = [:]
    /// The frame each window has on screen as far as we know: set by us or read.
    var frames: [WindowID: CGRect] = [:]
    /// The frame we last asked for: layouts are diffed against it, so a window that can't
    /// take a frame (minimum size) isn't asked again on every change.
    var targets: [WindowID: CGRect] = [:]
    /// When we last set each window's frame: its own move notifications follow shortly.
    var setAt: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows whose new frame is checked against the window server shortly after it's set,
    /// and the ones already set a second time for their current target.
    var unverified: Set<WindowID> = []
    var resent: Set<WindowID> = []
    var verifying: Task<Void, Never>?
    /// Windows parked off-screen, with the frame to give back to floating ones.
    var parked: [WindowID: CGRect] = [:]
    var snapChecks: [WindowID: Task<Void, Never>] = [:]
    /// Pending `refresh`es, by app.
    var refreshes: [pid_t: Task<Void, Never>] = [:]
    /// macOS native tabs (Finder, Safari, Terminal...): every tab is a window, but a tab
    /// group is one tile. Tab window -> the window that represents its group in the model.
    var tabs: [WindowID: WindowID] = [:]
    /// Group window -> the tab currently shown, which is what focusing the group raises.
    var shownTab: [WindowID: WindowID] = [:]

    /// Apps present at launch still reading their windows (for `if.during-aerospace-startup`
    /// and the saved layout). Other apps launching meanwhile don't count.
    var startingApps: Set<pid_t> = []
    var isStartingUp = true
    /// The layout saved by the last `stop()`, put back once every app's windows are read.
    var savedLayout: WMSnapshot?
    /// Bundle id -> the workspace its windows were on when the last one closed: an app
    /// opened again goes back there. Kept across restarts.
    var appWorkspaces: [String: String] = [:]
    /// `scratchpad` opened an app that had no window, or `--new` pressed its ⌘N menu item:
    /// the window it opens shortly is the scratchpad. After ⌘N, one that floats is a dialog
    /// or panel (a template chooser) and doesn't count.
    var pendingScratchpad: (bundleID: String, until: ContinuousClock.Instant, pressed: Bool)?
    /// When the focused window last closed, and the window a command last moved the focus
    /// away from (see `isStaleFocus`).
    var focusedClosedAt: ContinuousClock.Instant?
    var leftByCommand: (window: WindowID, at: ContinuousClock.Instant)?
    /// Callbacks don't retrigger themselves (AeroSpace's "recursion resistant").
    var inCallback = false
    /// The last layout applied: what `focus-follows-mouse` looks windows up in.
    var lastLayout = WMLayout()
    /// Displays left out by `ignore-monitor`, by name, as if disconnected.
    var ignoredMonitors: Set<String> = []
    /// `detect-monitor-input`: the input each display was last read showing, and the one
    /// that is the Mac's (the first one read, unless `ignore-monitor off` said otherwise;
    /// kept across restarts), by name.
    var monitorInputs: [String: UInt8] = [:]
    var macInputs: [String: UInt8] = [:]
    var inputPolling: Task<Void, Never>?

    public convenience init(handlers: Handlers) {
        self.init(handlers: handlers, system: MacSystem())
    }

    init(handlers: Handlers, system: WindowSystem) {
        self.handlers = handlers
        self.system = system
    }

    public var focusedWorkspace: String? { model?.focusedWorkspace.name }

    /// Where scratchpads with no workspace of their own go when put away (for the menu).
    public var scratchpadFallbackWorkspace: String { settings.scratchpadFallbackWorkspace }

    /// The workspace each display shows, the main display first and the others left to
    /// right, and which one is focused: what the menu bar shows.
    public var shownWorkspaces: [(name: String, focused: Bool)] {
        guard let model else { return [] }
        let focused = model.focusedWorkspace.name
        // `model.monitors` is already left to right; a stable sort brings the main one first.
        return (model.monitors.filter(\.isMain) + model.monitors.filter { !$0.isMain })
            .compactMap { model.visible[$0.id] }.map { ($0, $0 == focused) }
    }

    /// What `changed` last reported, so it's called only when the menu bar would change.
    private var announced: [String] = []

    /// Tells the menu bar if the focused workspace or any display's workspace changed.
    func announce() {
        let shown = shownWorkspaces.map { ($0.focused ? "*" : "") + $0.name }
        guard shown != announced else { return }
        announced = shown
        handlers.changed()
    }

    // MARK: - Lifecycle

    public func start(_ settings: WMSettings) {
        self.settings = settings
        if let model {
            model.settings = settings
            if settings.modes[mode] == nil { setMode("main") }
            pollMonitorInputs(settings.detectMonitorInput)
            // `detect-monitor-input` turned off: the displays it left out come back.
            if Set(shownMonitors().map(\.id)) != Set(model.monitors.map(\.id)) { monitorsChanged() } else { apply() }
            return
        }
        macInputs = loadMacInputs()
        model = WMModel(monitors: shownMonitors(), settings: settings)
        isStartingUp = true
        savedLayout = loadLayout()
        appWorkspaces = loadAppWorkspaces()
        pollMonitorInputs(settings.detectMonitorInput)
        system.observe { [weak self] event in self?.handle(event) }
        startingApps = Set(system.runningApps().map(\.pid))
        for pid in startingApps { watch(pid) }
        if startingApps.isEmpty { startedUp() }
        log.info("window manager started")
        announce()
    }

    /// Gives every window back: parked ones return on screen, nothing stays managed.
    public func stop() {
        guard let current = model else { return }
        if !isStartingUp { saveLayout(current) }
        for (id, frame) in parked { records[id]?.app.setFrames([(id, frame, frames[id])]) }
        // Frames are set on the apps' queues: on quit, the process would end before they
        // are, leaving windows off screen (and the next start would take them for windows
        // of another display). A frozen app doesn't hold the quit up for long.
        let group = DispatchGroup()
        for app in apps.values { app.flush(group) }
        if group.wait(timeout: .now() + .seconds(2)) == .timedOut { log.error("stopping: apps slow to take their windows back") }
        system.stopObserving()
        pollMonitorInputs(false)
        for app in apps.values { app.stop() }
        apps = [:]
        snapChecks.values.forEach { $0.cancel() }
        snapChecks = [:]
        refreshes.values.forEach { $0.cancel() }
        refreshes = [:]
        records = [:]
        frames = [:]
        targets = [:]
        setAt = [:]
        verifying?.cancel()
        verifying = nil
        unverified = []
        resent = []
        parked = [:]
        tabs = [:]
        shownTab = [:]
        savedLayout = nil
        startingApps = []
        lastLayout = WMLayout()
        model = nil
        setMode("main")
        log.info("window manager stopped")
        announced = []
        handlers.changed()
    }

    // MARK: - Applying the model

    /// Puts every window where the model says, touching only what changed (everything when
    /// `force`d: our idea of where windows are may be stale).
    func apply(force: Bool = false) {
        // Windows wait where they are for the saved layout: tiled meanwhile wherever they
        // were found, some apps would keep the size of that passing tile.
        guard let model, !(isStartingUp && savedLayout != nil) else { return }
        let layout = model.layout()
        lastLayout = layout
        var batches: [pid_t: (WindowApp, [(window: WindowID, frame: CGRect, old: CGRect?)])] = [:]
        let now = ContinuousClock.now
        func set(_ id: WindowID, _ frame: CGRect) {
            guard let app = records[id]?.app else { return }
            guard force || targets[id].map({ !$0.isClose(to: frame) }) ?? true else { return }
            let old = force ? nil : frames[id]
            frames[id] = frame
            targets[id] = frame
            setAt[id] = now
            resent.remove(id)
            unverified.insert(id)
            batches[app.pid, default: (app, [])].1.append((id, frame, old))
        }
        // Show first, then hide: less flicker when switching workspaces.
        for (id, frame) in layout.tiled {
            parked[id] = nil
            set(id, frame)
        }
        for (id, monitorID) in layout.floating {
            let parkedFrame = parked.removeValue(forKey: id)
            guard let frame = parkedFrame ?? frames[id] else { continue }
            // A floating window off every display (its display left) comes back on its monitor.
            if !model.monitors.contains(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
               let monitor = model.monitors.first(where: { $0.id == monitorID }) {
                let v = monitor.visible, size = CGSize(width: min(frame.width, v.width), height: min(frame.height, v.height))
                set(id, CGRect(origin: CGPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2), size: size).integral)
            } else if parkedFrame != nil || force {
                set(id, frame)
            }
        }
        for (id, monitorID) in layout.hidden {
            guard let monitor = model.monitors.first(where: { $0.id == monitorID }), let frame = parked[id] ?? frames[id] else { continue }
            if parked[id] == nil { parked[id] = frame }
            // Bottom right corner, one point inside so macOS doesn't pull the window back. Set
            // again when the corner moves (the workspace's display left): a no-op otherwise.
            set(id, CGRect(origin: CGPoint(x: monitor.visible.maxX - 1, y: monitor.visible.maxY - 1), size: frame.size))
        }
        // Tabs follow their group: same frame, parked with it.
        for (tab, group) in tabs {
            guard let target = targets[group] else { continue }
            if let frame = parked[group] {
                if parked[tab] == nil { parked[tab] = frame }
            } else {
                parked[tab] = nil
            }
            set(tab, target)
        }
        for (_, (app, changes)) in batches { app.setFrames(changes) }
        if !batches.isEmpty { verifyFrames() }
    }

    /// A frame can be lost: the app was busy past the AX timeout, our idea of where the
    /// window was is stale (only what differs is set), or macOS clamped it mid-move. Shortly
    /// after, the window server (no IPC) says where windows are; ones off their target get
    /// their whole frame once more, then whatever they took is accepted (a minimum size).
    private func verifyFrames() {
        guard verifying == nil else { return }
        verifying = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.verifying = nil
            let ids = Array(self.unverified)
            self.unverified = []
            let server = self.system.windowServer(ids)
            var batches: [pid_t: (WindowApp, [(window: WindowID, frame: CGRect, old: CGRect?)])] = [:]
            for id in ids {
                guard let target = self.targets[id], let bounds = server[id]?.bounds, !bounds.isClose(to: target),
                      let app = self.records[id]?.app else { continue }
                if self.resent.insert(id).inserted {
                    self.setAt[id] = .now
                    self.unverified.insert(id)
                    batches[app.pid, default: (app, [])].1.append((id, target, nil))
                } else {
                    self.frames[id] = bounds
                }
            }
            for (_, (app, changes)) in batches { app.setFrames(changes) }
            if !batches.isEmpty { self.verifyFrames() }
        }
    }

    /// Raises and focuses the model's focused window, as macOS would on a click.
    func focusNative() {
        guard let focused = model?.focused else { return }
        let shown = shownTab[focused] ?? focused
        records[shown]?.app.focus(shown)
    }
}

extension CGRect {
    /// Equal within a point: apps round frames their own way.
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
