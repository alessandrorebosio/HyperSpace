import AppKit
import ApplicationServices

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    var isFloating = false
    /// Set once the user toggles floating by hand; config reloads then leave it alone.
    var userOverride = false

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, bundleID: String?) {
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
    }
}

private struct ScreenState {
    var layout: LayoutKind
    var ratio: CGFloat
}

private struct DragSession {
    let mode: DragMode
    let element: AXUIElement
    let id: CGWindowID?
    let start: CGPoint
    let frame: CGRect
}

/// Event-driven tiling window manager.
///
/// - Window lifecycle comes from AX observers and NSWorkspace notifications (no polling).
/// - Which windows are visible (current Space, not minimized, app not hidden) and where
///   they are is read from one `CGWindowListCopyWindowInfo` call per retile, which needs
///   no Screen Recording permission as long as window titles are not requested.
/// - Frames are only written when they differ from the target, so a retile with
///   nothing to do costs a single window-server query.
final class WindowManager {
    private(set) var config = TilingConfig()
    private var running = false
    private var apps: [pid_t: AppWatcher] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    /// Tiling order; the first window of each screen is the master.
    private var order: [CGWindowID] = []
    private var screenStates: [CGDirectDisplayID: ScreenState] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var retileScheduled = false
    private var drag: DragSession?
    private lazy var refcon = Unmanaged.passUnretained(self).toOpaque()

    var isEnabled: Bool { config.enabled }

    var currentLayout: LayoutKind {
        state(for: activeScreen()?.id).layout
    }

    // MARK: - Lifecycle

    func apply(_ newConfig: TilingConfig) {
        if newConfig.layout != config.layout || newConfig.masterRatio != config.masterRatio {
            screenStates.removeAll()
        }
        config = newConfig
        for window in windows.values where !window.userOverride {
            window.isFloating = config.floating.contains(window.bundleID ?? "")
        }
        config.enabled ? start() : stop()
        scheduleRetile()
    }

    func toggleEnabled() {
        config.enabled.toggle()
        config.enabled ? start() : stop()
        scheduleRetile()
    }

    private func start() {
        guard !running else { return }
        running = true

        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (NSRunningApplication?) -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                handler(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            if let app { self?.addApp(app) }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            if let app { self?.removeApp(app.processIdentifier) }
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            // Windows living on other Spaces are only listed by AX once visible.
            guard let self, let app else { return }
            if let watcher = apps[app.processIdentifier] {
                if discover(watcher) { scheduleRetile() }
            } else {
                addApp(app)
            }
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] _ in self?.scheduleRetile() }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.scheduleRetile() }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.rescan() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRetile() }

        for app in NSWorkspace.shared.runningApplications { addApp(app) }
        scheduleRetile()
    }

    private func stop() {
        guard running else { return }
        running = false
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        apps.values.forEach { $0.invalidate() }
        apps.removeAll()
        windows.removeAll()
        order.removeAll()
    }

    // MARK: - Tracking

    private func addApp(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard running, app.activationPolicy == .regular, pid != getpid(), apps[pid] == nil, !app.isTerminated else { return }
        if let watcher = AppWatcher(app: app, refcon: refcon) {
            apps[pid] = watcher
            if discover(watcher) { scheduleRetile() }
        } else if attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.addApp(app, attempt: attempt + 1)
            }
        }
    }

    private func removeApp(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.invalidate()
        for (id, window) in windows where window.pid == pid { untrack(id) }
        scheduleRetile()
    }

    /// Returns true if new windows were found.
    @discardableResult
    private func discover(_ watcher: AppWatcher) -> Bool {
        var found = false
        for element in watcher.windows where track(element, in: watcher) { found = true }
        return found
    }

    private func track(_ element: AXUIElement, in watcher: AppWatcher) -> Bool {
        guard let id = AX.windowID(element), windows[id] == nil, AX.isStandardWindow(element) else { return false }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isFloating = config.floating.contains(watcher.bundleID ?? "")
        windows[id] = window
        order.append(id)
        watcher.watchDestroyed(element)
        return true
    }

    private func untrack(_ id: CGWindowID) {
        windows[id] = nil
        order.removeAll { $0 == id }
    }

    /// Space switch: pick up windows AX could not see before and drop dead ones.
    private func rescan() {
        let alive = Set(
            (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )
        for id in windows.keys where !alive.contains(id) { untrack(id) }
        for watcher in apps.values { discover(watcher) }
        scheduleRetile()
    }

    func handle(_ notification: String, element: AXUIElement) {
        guard running else { return }
        let pid = AX.pid(element)
        switch notification {
        case kAXWindowCreatedNotification:
            guard let watcher = apps[pid], track(element, in: watcher) else { return }
            scheduleRetile()
            // Some apps put the window on screen a moment after announcing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scheduleRetile() }
        case kAXUIElementDestroyedNotification:
            guard let id = windows.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) })?.key else { return }
            untrack(id)
            scheduleRetile()
        default:
            scheduleRetile()
        }
    }

    // MARK: - Layout

    /// Coalesces bursts of events (an app opening five windows) into one retile.
    private func scheduleRetile() {
        guard running, !retileScheduled else { return }
        retileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.retileScheduled = false
            self?.retile()
        }
    }

    func retileNow() {
        retile()
    }

    private func retile() {
        guard running, config.enabled, drag == nil else { return }
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return }
        let bounds = onScreenBounds()

        var buckets = [[ManagedWindow]](repeating: [], count: screens.count)
        for id in order {
            guard let window = windows[id], !window.isFloating, let frame = bounds[id] else { continue }
            let index = screens.index(for: frame)
            // A native full-screen window covers the whole display, menu bar included.
            if frame.isClose(to: screens[index].frame) { continue }
            buckets[index].append(window)
        }

        for (index, tiled) in buckets.enumerated() where !tiled.isEmpty {
            let screen = screens[index]
            let state = state(for: screen.id)
            let area = screen.visible.insetBy(dx: config.padding, dy: config.padding)
            let frames = Layout.frames(state.layout, count: tiled.count, in: area, gap: config.gap, ratio: state.ratio)
            for (window, frame) in zip(tiled, frames) where !(bounds[window.id]?.isClose(to: frame) ?? false) {
                setFrame(window, frame)
            }
        }
    }

    private func setFrame(_ window: ManagedWindow, _ frame: CGRect) {
        // AXEnhancedUserInterface (set by VoiceOver-aware tools) makes some apps
        // animate every AX resize; switch it off while we move the window.
        let app = apps[window.pid]?.element
        let enhanced = app.flatMap { AX.bool($0, "AXEnhancedUserInterface") } ?? false
        if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", false) }
        // size → position → size: the first resize lets the window fit on the
        // destination display, the second fixes apps that clamp to the old screen.
        AX.setSize(window.element, frame.size)
        AX.setPosition(window.element, frame.origin)
        AX.setSize(window.element, frame.size)
        if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", true) }
    }

    /// Visible, normal-layer windows on the current Space with their frames.
    private func onScreenBounds() -> [CGWindowID: CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var result = [CGWindowID: CGRect](minimumCapacity: list.count)
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { continue }
            result[id] = rect
        }
        return result
    }

    private func state(for screen: CGDirectDisplayID?) -> ScreenState {
        screen.flatMap { screenStates[$0] } ?? ScreenState(layout: config.layout, ratio: config.masterRatio)
    }

    private func updateActiveScreen(_ change: (inout ScreenState) -> Void) {
        guard let id = activeScreen()?.id else { return }
        var state = state(for: id)
        change(&state)
        screenStates[id] = state
        scheduleRetile()
    }

    // MARK: - Commands

    private func focused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element) else { return nil }
        return windows[id]
    }

    private func activeScreen() -> ScreenInfo? {
        let screens = ScreenInfo.current()
        if let window = focused(), let frame = onScreenBounds()[window.id] {
            return screens[screens.index(for: frame)]
        }
        return screens.first
    }

    func focus(_ direction: Direction) {
        let bounds = onScreenBounds()
        guard let current = focused(), let origin = bounds[current.id] else { return }
        let candidates = windows.values.compactMap { w in w.id == current.id ? nil : bounds[w.id].map { (w, $0) } }
        if let target = Layout.neighbor(of: origin, direction, among: candidates) {
            AX.focus(target.element, pid: target.pid)
        }
    }

    func swap(_ direction: Direction) {
        let bounds = onScreenBounds()
        guard let current = focused(), !current.isFloating, let origin = bounds[current.id] else { return }
        let candidates = windows.values.compactMap { w in
            w.id == current.id || w.isFloating ? nil : bounds[w.id].map { (w, $0) }
        }
        guard let target = Layout.neighbor(of: origin, direction, among: candidates), let targetFrame = bounds[target.id] else { return }
        swapOrder(current.id, target.id)
        // Exchanging frames also carries the windows across displays.
        setFrame(current, targetFrame)
        setFrame(target, origin)
        scheduleRetile()
    }

    func swapMaster() {
        let bounds = onScreenBounds()
        let screens = ScreenInfo.current()
        guard let current = focused(), !current.isFloating, let frame = bounds[current.id] else { return }
        let screen = screens.index(for: frame)
        let master = order.first { id in
            guard let w = windows[id], !w.isFloating, let f = bounds[id] else { return false }
            return screens.index(for: f) == screen
        }
        guard let master, master != current.id else { return }
        swapOrder(current.id, master)
        scheduleRetile()
    }

    private func swapOrder(_ a: CGWindowID, _ b: CGWindowID) {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return }
        order.swapAt(i, j)
    }

    func setLayout(_ kind: LayoutKind) {
        updateActiveScreen { $0.layout = kind }
    }

    func nextLayout() {
        updateActiveScreen { state in
            let all = LayoutKind.allCases
            state.layout = all[(all.firstIndex(of: state.layout)! + 1) % all.count]
        }
    }

    func adjustRatio(_ delta: CGFloat) {
        updateActiveScreen { $0.ratio = min(0.9, max(0.1, $0.ratio + delta)) }
    }

    func toggleFloat() {
        guard let window = focused() else { return }
        window.isFloating.toggle()
        window.userOverride = true
        if window.isFloating { AX.focus(window.element, pid: window.pid) }
        scheduleRetile()
    }

    func moveToNextDisplay() {
        let screens = ScreenInfo.current()
        guard screens.count > 1, let window = focused(), let frame = onScreenBounds()[window.id] else { return }
        let next = screens[(screens.index(for: frame) + 1) % screens.count].visible
        let size = CGSize(width: min(frame.width, next.width), height: min(frame.height, next.height))
        let origin = CGPoint(x: next.midX - size.width / 2, y: next.midY - size.height / 2)
        setFrame(window, CGRect(origin: origin, size: size))
        AX.focus(window.element, pid: window.pid)
        scheduleRetile()
    }

    // MARK: - Mouse drag (modifier + left drag moves, modifier + right drag resizes)

    func beginDrag(_ mode: DragMode, at point: CGPoint) {
        guard let element = AX.window(at: point),
              let origin = AX.position(element), let size = AX.size(element) else { return }
        AX.focus(element, pid: AX.pid(element))
        drag = DragSession(mode: mode, element: element, id: AX.windowID(element), start: point,
                           frame: CGRect(origin: origin, size: size))
    }

    func updateDrag(to point: CGPoint) {
        guard let drag else { return }
        let dx = point.x - drag.start.x
        let dy = point.y - drag.start.y
        switch drag.mode {
        case .move:
            AX.setPosition(drag.element, CGPoint(x: drag.frame.minX + dx, y: drag.frame.minY + dy))
        case .resize:
            AX.setSize(drag.element, CGSize(width: max(160, drag.frame.width + dx), height: max(100, drag.frame.height + dy)))
        }
    }

    func endDrag(at point: CGPoint) {
        guard let session = drag else { return }
        drag = nil
        guard running, let id = session.id, let window = windows[id], !window.isFloating else { return }

        let bounds = onScreenBounds()
        switch session.mode {
        case .move:
            // Dropping a tiled window onto another one swaps them.
            if let target = order.first(where: { $0 != id && windows[$0]?.isFloating == false && bounds[$0]?.contains(point) == true }) {
                swapOrder(id, target)
            }
        case .resize:
            // Resizing a tiled window drags the master/stack split instead.
            let screens = ScreenInfo.current()
            guard let frame = bounds[id], !screens.isEmpty else { break }
            let screen = screens[screens.index(for: frame)]
            var state = state(for: screen.id)
            let isMaster = order.first { other in
                guard windows[other]?.isFloating == false, let f = bounds[other] else { return false }
                return screens.index(for: f) == screens.index(for: frame)
            } == id
            let delta: CGFloat
            switch state.layout {
            case .tall: delta = (point.x - session.start.x) / screen.visible.width
            case .wide: delta = (point.y - session.start.y) / screen.visible.height
            case .columns, .monocle: delta = 0
            }
            state.ratio = min(0.9, max(0.1, state.ratio + (isMaster ? delta : -delta)))
            screenStates[screen.id] = state
        }
        scheduleRetile()
    }
}
