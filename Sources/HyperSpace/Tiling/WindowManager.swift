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
    var workspace = 0
    /// Where the window was before its workspace was hidden.
    var hiddenFrame: CGRect?
    /// Share of the split it is in (stack or columns), changed by resizing.
    var weight: CGFloat = 1
    /// When we last moved it: the moves this causes are ours, not the user's.
    var movedByUs = Date.distantPast

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, bundleID: String?) {
        self.id = id
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// What the menu bar shows for a workspace.
struct WorkspaceSummary {
    struct Window {
        let id: CGWindowID
        let app: String
        let title: String?
        let icon: NSImage?
    }

    let index: Int
    let name: String
    /// 1-based display (left to right) showing it, if any.
    let display: Int?
    let windows: [Window]
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

/// Event-driven tiling window manager with virtual workspaces.
///
/// - Window lifecycle comes from AX observers and NSWorkspace notifications (no polling).
/// - Which windows are visible (current Space, not minimized, app not hidden) and where
///   they are is read from one `CGWindowListCopyWindowInfo` call per retile, which needs
///   no Screen Recording permission as long as window titles are not requested.
/// - Frames are only written when they differ from the target, so a retile with
///   nothing to do costs a single window-server query.
/// - Workspaces are virtual (macOS offers no public API to drive Spaces). Each one lives on
///   a display: workspace 1 the main display, 2 the second, and so on, the rest on the
///   main display, until moved to another display. Each display shows one of its
///   workspaces (or none when all of them were moved away). Every window belongs
///   to a workspace; windows of workspaces not shown are parked in the bottom-right
///   corner of their screen.
///   They are always brought back on quit, when tiling is turned off, and on the next
///   launch after a crash.
final class WindowManager {
    private(set) var config = TilingConfig()
    /// Called with the workspace shown on each display (left to right) and the index of
    /// the focused display, or nil when workspaces are not in use.
    var onWorkspaceChange: (((names: [String], focused: Int)?) -> Void)?

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

    /// The workspace each display shows.
    private var displayed: [CGDirectDisplayID: Int] = [:]
    /// Workspaces moved to another display than their default one.
    private var homeOverride: [Int: CGDirectDisplayID] = [:]
    /// The workspace each display showed before the current one.
    private var shownBefore: [CGDirectDisplayID: Int] = [:]
    /// Column arrangement of each workspace (columns layout).
    private var columns: [Int: ColumnLayout] = [:]
    private var previousWorkspace: Int?
    private var lastFocused: [Int: CGWindowID] = [:]
    /// Focus changes we cause ourselves must not switch workspace back.
    private var followFocusAfter = Date.distantPast
    /// A window just moved to a hidden workspace that still has focus: it must not drag
    /// its workspace onto the screen. Cleared as soon as focus goes elsewhere.
    private var movedAway: CGWindowID?
    /// The display the user works on, set when we move the focus there: an empty workspace
    /// has no window to tell, and the pointer may still be on the other display.
    private var activeDisplay: CGDirectDisplayID?
    /// Last value sent to `onWorkspaceChange`, so the menu bar is redrawn only on change.
    private var lastNotice: (names: [String], focused: Int)??
    /// Workspaces apps were opened from, for the windows they show while loading.
    private var launches = LaunchTracker()
    private var focusUpdateScheduled = false
    private var snapBackScheduled = false

    /// At least one workspace per display, even when fewer are configured.
    private var workspaceCount: Int { max(1, config.workspaces.count, NSScreen.screens.count) }

    private func name(of workspace: Int) -> String {
        workspace < config.workspaces.count ? config.workspaces[workspace] : "\(workspace + 1)"
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
        // Fewer workspaces than before: their windows join the first one.
        displayed = displayed.filter { $0.value < workspaceCount }
        homeOverride = homeOverride.filter { $0.key < workspaceCount }
        shownBefore = shownBefore.filter { $0.value < workspaceCount }
        if let previous = previousWorkspace, previous >= workspaceCount { previousWorkspace = nil }
        for window in windows.values where window.workspace >= workspaceCount { window.workspace = 0 }
        config.enabled ? start() : stop()
        notifyWorkspace()
        scheduleRetile()
    }

    func toggleEnabled() {
        config.enabled.toggle()
        config.enabled ? start() : stop()
        scheduleRetile()
    }

    /// Puts every parked window back where it was (on quit).
    func restoreHiddenWindows() {
        for window in windows.values {
            guard let frame = window.hiddenFrame else { continue }
            setFrame(window, frame)
            window.hiddenFrame = nil
        }
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
            guard let self, let app else { return }
            if let workspace = focusedScreen().flatMap({ self.displayed[$0.id] }) {
                launches.launched(app.processIdentifier, in: workspace)
            }
            addApp(app)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            launches.forget(app.processIdentifier)
            removeApp(app.processIdentifier)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            // Windows living on other Spaces are only listed by AX once visible.
            guard let self, let app else { return }
            if let watcher = apps[app.processIdentifier] {
                if discover(watcher) { scheduleRetile() }
            } else {
                addApp(app)
            }
            scheduleFocusUpdate()
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] _ in self?.scheduleRetile() }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] _ in self?.scheduleRetile() }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.rescan() }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncDisplays()
            self?.scheduleRetile()
            self?.notifyWorkspace()
        }

        syncDisplays()
        for app in NSWorkspace.shared.runningApplications { addApp(app) }
        rescueStrandedWindows()
        scheduleRetile()
        // Right after a login or a WindowServer restart, or on a busy Mac, apps can answer AX
        // with placeholder elements: look again once they have settled.
        for delay in [2.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rescan() }
        }
    }

    private func stop() {
        guard running else { return }
        restoreHiddenWindows()
        running = false
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        apps.values.forEach { $0.invalidate() }
        apps.removeAll()
        launches.removeAll()
        windows.removeAll()
        order.removeAll()
        lastFocused.removeAll()
        displayed.removeAll()
        homeOverride.removeAll()
        shownBefore.removeAll()
        activeDisplay = nil
    }

    /// After a crash windows can be left parked off-screen: bring them back.
    private func rescueStrandedWindows() {
        let screens = ScreenInfo.current()
        guard let main = screens.first else { return }
        for (id, frame) in onScreenBounds() {
            guard let window = windows[id] else { continue }
            let visible = screens.map { $0.frame.intersection(frame) }.map { $0.isNull ? 0 : $0.width * $0.height }.max() ?? 0
            guard visible < frame.width * frame.height * 0.1 else { continue }
            setFrame(window, main.centered(frame.size))
        }
    }

    // MARK: - Tracking

    private func addApp(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard running, app.activationPolicy == .regular, pid != getpid(), apps[pid] == nil, !app.isTerminated else { return }
        if let watcher = AppWatcher(app: app, refcon: refcon) {
            apps[pid] = watcher
            log.debug("watch \(watcher.bundleID ?? "?", privacy: .public): \(watcher.windows.count) window(s)")
            if discover(watcher) { scheduleRetile() }
        } else if attempt < 20 {
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
        for element in watcher.windows where track(element, in: watcher) != nil { found = true }
        return found
    }

    /// Starts managing a window; nil when it is already known or not a standard window.
    @discardableResult
    private func track(_ element: AXUIElement, in watcher: AppWatcher) -> ManagedWindow? {
        guard let id = AX.windowID(element) else {
            // The Finder desktop (a scroll area) is listed among its windows: not worth a line.
            guard AX.string(element, kAXRoleAttribute) != kAXScrollAreaRole else { return nil }
            log.debug("no window id for a window of \(watcher.bundleID ?? "?", privacy: .public) (role \(AX.string(element, kAXRoleAttribute) ?? "-", privacy: .public))")
            return nil
        }
        guard windows[id] == nil else { return nil }
        guard AX.isStandardWindow(element) else {
            log.debug("skip window of \(watcher.bundleID ?? "?", privacy: .public): role \(AX.string(element, kAXRoleAttribute) ?? "-", privacy: .public) subrole \(AX.string(element, kAXSubroleAttribute) ?? "-", privacy: .public)")
            return nil
        }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isFloating = config.floating.contains(watcher.bundleID ?? "")
        // A window joins its app's assigned workspace, the one the app was opened from
        // (you may have moved on while it loaded), or the one shown where it appears.
        let launch = launches.workspace(for: watcher.pid)
        if let assigned = watcher.bundleID.flatMap({ config.assignments[$0] }), assigned < workspaceCount {
            window.workspace = assigned
        } else if let launch, launch < workspaceCount {
            window.workspace = launch
        } else if let origin = AX.position(element), let size = AX.size(element), case let screens = ScreenInfo.current(), !screens.isEmpty {
            window.workspace = displayed[screens[screens.index(for: CGRect(origin: origin, size: size))].id] ?? 0
        } else {
            window.workspace = focusedScreen().flatMap { displayed[$0.id] } ?? 0
        }
        windows[id] = window
        order.append(id)
        watcher.watch(element)
        log.debug("track \(watcher.bundleID ?? "?", privacy: .public) window \(id) workspace \(window.workspace) floating \(window.isFloating)")
        return window
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
            guard let watcher = apps[pid], let window = track(element, in: watcher) else { return }
            if display(showing: window.workspace) == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                lastFocused[window.workspace] = window.id
                if watcher.bundleID.flatMap({ config.assignments[$0] }) != nil {
                    // An app you just opened shows its assigned workspace, so its window is visible.
                    switchWorkspace(window.workspace)
                } else {
                    // It finished loading after you left its workspace: it stays there, and
                    // the focus stays where you are.
                    log.debug("window \(window.id) (\(watcher.bundleID ?? "?", privacy: .public)) opened in hidden workspace \(window.workspace)")
                    let here = activeDisplay.flatMap { displayed[$0] }
                    ignoreFocusChanges()
                    movedAway = window.id
                    retile()
                    if let here { focusWindow(in: here) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scheduleRetile() }
                }
                return
            }
            scheduleRetile()
            // Some apps put the window on screen a moment after announcing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scheduleRetile() }
        case kAXUIElementDestroyedNotification:
            guard let id = windows.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) })?.key else { return }
            untrack(id)
            scheduleRetile()
        case kAXMovedNotification, kAXResizedNotification:
            // Moved or resized by hand: back to its tile once the mouse is released. Our own
            // moves land on the target frame, so the retile has nothing to do for them.
            guard let window = windows.values.first(where: { $0.pid == pid && CFEqual($0.element, element) }),
                  !window.isFloating, window.hiddenFrame == nil,
                  // A window that cannot take its tile (a minimum size) must not loop.
                  Date().timeIntervalSince(window.movedByUs) > 0.5 else { return }
            scheduleSnapBack()
        case kAXFocusedWindowChangedNotification:
            scheduleFocusUpdate()
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

    /// An app activation and its focused-window change arrive together: one lookup for both.
    private func scheduleFocusUpdate() {
        guard running, !focusUpdateScheduled else { return }
        focusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusUpdateScheduled = false
            let window = focused()
            followFocus(window)
            notifyWorkspace(focused: window)
        }
    }

    /// Retiles once no mouse button is held (the user may still be dragging the window).
    private func scheduleSnapBack() {
        guard running, !snapBackScheduled else { return }
        snapBackScheduled = true
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if NSEvent.pressedMouseButtons != 0 { return check() }
                snapBackScheduled = false
                scheduleRetile()
            }
        }
        check()
    }

    func retileNow() {
        retile()
    }

    private func retile() {
        guard running, config.enabled, drag == nil else { return }
        syncDisplays()
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return }
        let bounds = onScreenBounds()
        let shown = Set(displayed.values)

        for window in windows.values {
            if !shown.contains(window.workspace) {
                if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame, screens: screens) }
            } else if window.isFloating, let screen = screens.first(where: { displayed[$0.id] == window.workspace }) {
                show(window, on: screen)
            }
        }

        for screen in screens {
            guard let workspace = displayed[screen.id] else { continue }
            let tiled = tiledWindows(in: workspace, bounds: bounds).filter { window in
                // A native full-screen window covers the whole display, menu bar included.
                window.hiddenFrame != nil || !screens.contains { bounds[window.id]!.isClose(to: $0.frame) }
            }
            guard !tiled.isEmpty else { continue }
            let state = state(for: screen.id)
            log.debug("retile display \(screen.id) workspace \(workspace): \(tiled.count) tiled \(tiled.map { $0.bundleID ?? "?" }, privacy: .public)")
            let frames: [CGWindowID: CGRect]
            if state.layout == .columns {
                var layout = columns[workspace] ?? ColumnLayout()
                layout.sync(with: tiled.map(\.id))
                columns[workspace] = layout
                frames = layout.frames(in: area(of: screen), gap: config.gap) { windows[$0]?.weight ?? 1 }
            } else {
                let list = Layout.frames(state.layout, weights: tiled.map(\.weight), in: area(of: screen),
                                         gap: config.gap, ratio: state.ratio)
                frames = Dictionary(uniqueKeysWithValues: zip(tiled.map(\.id), list))
            }
            for window in tiled {
                guard let frame = frames[window.id] else { continue }
                window.hiddenFrame = nil
                if !(bounds[window.id]?.isClose(to: frame) ?? false) { setFrame(window, frame) }
            }
        }
    }

    private func area(of screen: ScreenInfo) -> CGRect {
        screen.visible.insetBy(dx: config.padding, dy: config.padding)
    }

    /// Tiled windows of a workspace that are on screen, in tiling order.
    private func tiledWindows(in workspace: Int, bounds: [CGWindowID: CGRect]) -> [ManagedWindow] {
        order.compactMap { windows[$0] }.filter { $0.workspace == workspace && !$0.isFloating && bounds[$0.id] != nil }
    }

    /// Focus changes in the next moment come from us (hiding windows makes apps refocus),
    /// not from the user, and must not switch workspaces.
    private func ignoreFocusChanges() {
        followFocusAfter = Date().addingTimeInterval(0.6)
    }

    /// Focuses a window without the resulting focus change switching workspaces. Crossing
    /// to another display brings the pointer along (if enabled), and as macOS sometimes
    /// ignores a background app raising a window on another display, it checks and retries.
    private func focus(_ window: ManagedWindow) {
        ignoreFocusChanges()
        AX.focus(window.element, pid: window.pid)
        let screens = ScreenInfo.current()
        if let frame = onScreenBounds()[window.id], !screens.isEmpty {
            let screen = screens[screens.index(for: frame)]
            activeDisplay = screen.id
            bringPointer(to: frame.center, on: screen, screens)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
            log.debug("focus did not take for window \(window.id) (\(window.bundleID ?? "?", privacy: .public)), retrying")
            self?.ignoreFocusChanges()
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
            AX.focus(window.element, pid: window.pid)
        }
    }

    /// Moves the pointer to `point` when it is on another display than `screen`.
    private func bringPointer(to point: CGPoint, on screen: ScreenInfo, _ screens: [ScreenInfo]) {
        guard config.mouseFollowsFocus, !screen.frame.contains(AX.pointer) else { return }
        AX.warpPointer(to: point)
    }

    private func setFrame(_ window: ManagedWindow, _ frame: CGRect) {
        // AXEnhancedUserInterface (set by VoiceOver-aware tools) makes some apps
        // animate every AX resize; switch it off while we move the window.
        window.movedByUs = Date()
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
        guard let id = focusedScreen()?.id else { return }
        var state = state(for: id)
        change(&state)
        screenStates[id] = state
        scheduleRetile()
    }

    // MARK: - Workspaces

    /// The display a workspace lives on: where it was moved, otherwise workspace n on the
    /// n-th display and the rest on the main one (displays in `ScreenInfo.current()` order).
    private func home(of workspace: Int, _ screens: [ScreenInfo]) -> ScreenInfo? {
        if let id = homeOverride[workspace], let screen = screens.first(where: { $0.id == id }) { return screen }
        return screens.isEmpty ? nil : screens[Self.homeIndex(of: workspace, displays: screens.count)]
    }

    /// Shows a workspace on a display, remembering what it replaces.
    private func show(_ workspace: Int?, on display: CGDirectDisplayID) {
        if let current = displayed[display], current != workspace { shownBefore[display] = current }
        displayed[display] = workspace
    }

    static func homeIndex(of workspace: Int, displays: Int) -> Int {
        workspace < displays ? workspace : 0
    }

    /// Every display shows one of its own workspaces (the lowest numbered by default), or
    /// none when no workspace lives there.
    private func syncDisplays() {
        let screens = ScreenInfo.current()
        let ids = Set(screens.map(\.id))
        displayed = displayed.filter { ids.contains($0.key) }
        for screen in screens {
            if let shown = displayed[screen.id], home(of: shown, screens)?.id == screen.id { continue }
            let taken = Set(displayed.values)
            displayed[screen.id] = (0..<workspaceCount).first { home(of: $0, screens)?.id == screen.id && !taken.contains($0) }
        }
    }

    private func display(showing workspace: Int) -> CGDirectDisplayID? {
        displayed.first { $0.value == workspace }?.key
    }

    /// Shows a workspace on its own display and focuses it; the other displays keep theirs.
    func switchWorkspace(_ index: Int) {
        guard running, (0..<workspaceCount).contains(index) else { return }
        syncDisplays()
        let screens = ScreenInfo.current()
        guard let screen = home(of: index, screens) else { return }
        // Even with nothing to focus (an empty workspace), the refocusing caused by hiding
        // the old windows must not bring the old workspace back.
        ignoreFocusChanges()
        let focusedWorkspace = focusedScreen().flatMap { displayed[$0.id] }
        log.debug("switch to workspace \(index) on display \(screen.id) (shown there: \(self.displayed[screen.id] ?? -1), focused: \(focusedWorkspace ?? -1))")
        if let current = focusedWorkspace, current != index {
            previousWorkspace = current
            if let window = focused(), window.workspace == current { lastFocused[current] = window.id }
        }
        if displayed[screen.id] != index {
            show(index, on: screen.id)
            retile()
        }
        focusWindow(in: index)
        notifyWorkspace()
    }

    func switchToPreviousWorkspace() {
        if let previousWorkspace { switchWorkspace(previousWorkspace) }
    }

    /// Moves only the focused window; the displays keep showing what they show.
    func moveFocusedWindow(toWorkspace index: Int) {
        guard running, (0..<workspaceCount).contains(index), let window = focused(), window.workspace != index else { return }
        let source = window.workspace
        ignoreFocusChanges()
        window.workspace = index
        log.debug("move window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) from workspace \(source) to \(index), shown: \(self.display(showing: index) != nil)")
        retile()
        guard display(showing: index) == nil else { return }
        // It went out of sight: focus what is left, and if nothing is, keep its workspace hidden.
        movedAway = window.id
        focusWindow(in: source)
    }

    /// Parks a window in the bottom-right corner of its screen, nearly all of it off-screen.
    private func hide(_ window: ManagedWindow, from frame: CGRect, screens: [ScreenInfo]) {
        guard window.hiddenFrame == nil, !screens.isEmpty else { return }
        window.hiddenFrame = frame
        let screen = screens[screens.index(for: frame)].frame
        AX.setPosition(window.element, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1))
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    private func show(_ window: ManagedWindow, on screen: ScreenInfo) {
        guard let frame = window.hiddenFrame else { return }
        setFrame(window, screen.frame.contains(frame.center) ? frame : screen.centered(frame.size))
        window.hiddenFrame = nil
    }

    /// Focuses the workspace: its last focused window, or with no windows, its display.
    private func focusWindow(in workspace: Int) {
        let bounds = onScreenBounds()
        let candidates = order.compactMap { windows[$0] }.filter { $0.workspace == workspace && bounds[$0.id] != nil }
        if let target = candidates.first(where: { $0.id == lastFocused[workspace] }) ?? candidates.first {
            focus(target)
        } else if let id = display(showing: workspace), case let screens = ScreenInfo.current(),
                  let screen = screens.first(where: { $0.id == id }) {
            activeDisplay = id
            bringPointer(to: screen.visible.center, on: screen, screens)
        }
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    private func followFocus(_ window: ManagedWindow?) {
        guard running, let window else { return }
        if window.hiddenFrame == nil, let id = display(showing: window.workspace) { activeDisplay = id }
        if window.id != movedAway { movedAway = nil }
        guard Date() > followFocusAfter, window.id != movedAway, display(showing: window.workspace) == nil else { return }
        log.debug("follow focus to window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) in workspace \(window.workspace)")
        switchWorkspace(window.workspace)
    }

    /// Tells the menu bar what each display shows; called often (every focus change), so it
    /// only looks up the focused display when there are several, and only reports changes.
    private func notifyWorkspace(focused window: ManagedWindow?? = nil) {
        var notice: (names: [String], focused: Int)?
        if running, config.enabled, config.workspaces.count > 1 {
            let screens = ScreenInfo.current()
            let names = screens.map { displayed[$0.id].map(name(of:)) ?? "–" }
            let focusedID = screens.count > 1 ? focusedScreen(window ?? focused())?.id : nil
            notice = (names, screens.firstIndex { $0.id == focusedID } ?? 0)
        }
        if let last = lastNotice, last?.names == notice?.names, last?.focused == notice?.focused { return }
        lastNotice = .some(notice)
        onWorkspaceChange?(notice)
    }

    // MARK: - Menu

    /// Every workspace with its windows in tiling order. Reads window titles, so it is
    /// meant for when the menu opens, not for hot paths.
    func summaries() -> [WorkspaceSummary] {
        guard running, config.enabled, config.workspaces.count > 1 else { return [] }
        syncDisplays()
        let screens = ScreenInfo.current()
        var apps: [pid_t: NSRunningApplication] = [:]
        return (0..<workspaceCount).map { index in
            let members = order.compactMap { windows[$0] }.filter { $0.workspace == index }
            let entries = members.map { window -> WorkspaceSummary.Window in
                let app = apps[window.pid] ?? NSRunningApplication(processIdentifier: window.pid)
                apps[window.pid] = app
                let title = AX.string(window.element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                return WorkspaceSummary.Window(id: window.id, app: app?.localizedName ?? window.bundleID ?? "App",
                                               title: title, icon: app?.icon)
            }
            let display = display(showing: index).flatMap { id in screens.firstIndex { $0.id == id } }.map { $0 + 1 }
            return WorkspaceSummary(index: index, name: name(of: index), display: display, windows: entries)
        }
    }

    /// Brings a window to the front, showing its workspace first if needed.
    func focusWindow(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        if display(showing: window.workspace) == nil {
            lastFocused[window.workspace] = id
            switchWorkspace(window.workspace)
        } else {
            focus(window)
            notifyWorkspace()
        }
    }

    // MARK: - Commands

    private func focused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element) else { return nil }
        return windows[id]
    }

    /// The display the user works on: the focused window's, else the one we last moved the
    /// focus to (an empty workspace has no window), else the one under the pointer.
    private func focusedScreen(_ focusedWindow: ManagedWindow?? = nil) -> ScreenInfo? {
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return nil }
        if let window = focusedWindow ?? focused(), window.hiddenFrame == nil, display(showing: window.workspace) != nil,
           let frame = onScreenBounds()[window.id] {
            return screens[screens.index(for: frame)]
        }
        if let id = activeDisplay, let screen = screens.first(where: { $0.id == id }) { return screen }
        let pointer = AX.pointer
        return screens.first { $0.frame.contains(pointer) } ?? screens.first
    }

    /// Windows of the displayed workspaces that are on screen, with their frames.
    private func visible(_ bounds: [CGWindowID: CGRect], tiledOnly: Bool = false) -> [(ManagedWindow, CGRect)] {
        let shown = Set(displayed.values)
        return windows.values.compactMap { window in
            guard shown.contains(window.workspace), window.hiddenFrame == nil, !(tiledOnly && window.isFloating) else { return nil }
            return bounds[window.id].map { (window, $0) }
        }
    }

    func focus(_ direction: Direction) {
        let bounds = onScreenBounds()
        guard let current = focused(), let origin = bounds[current.id] else { return }
        let candidates = visible(bounds).filter { $0.0.id != current.id }
        if let target = Layout.neighbor(of: origin, direction, among: candidates) { focus(target) }
    }

    /// The layout of the display showing a workspace.
    private func layout(of workspace: Int) -> LayoutKind {
        state(for: display(showing: workspace)).layout
    }

    func swap(_ direction: Direction) {
        let bounds = onScreenBounds()
        guard let current = focused(), !current.isFloating, let origin = bounds[current.id] else { return }
        if layout(of: current.workspace) == .columns, columns[current.workspace]?.locate(current.id) != nil {
            // Columns: stack, unstack and reorder (see ColumnLayout.move); new arrangement, even shares.
            columns[current.workspace]?.move(current.id, direction)
            current.weight = 1
            retile()
            return
        }
        let candidates = visible(bounds, tiledOnly: true).filter { $0.0.id != current.id }
        guard let target = Layout.neighbor(of: origin, direction, among: candidates), let targetFrame = bounds[target.id] else { return }
        swapOrder(current.id, target.id)
        Swift.swap(&current.weight, &target.weight)
        Swift.swap(&current.workspace, &target.workspace)
        // Exchanging frames also carries the windows across displays.
        setFrame(current, targetFrame)
        setFrame(target, origin)
        scheduleRetile()
    }

    func swapMaster() {
        let bounds = onScreenBounds()
        guard let current = focused(), !current.isFloating, bounds[current.id] != nil,
              let master = tiledWindows(in: current.workspace, bounds: bounds).first, master !== current else { return }
        swapOrder(current.id, master.id)
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

    /// Grows or shrinks the focused window by `delta` points. Floating windows are
    /// resized directly; tiled ones move the master/stack split or change their share
    /// of the stack (or of the columns).
    func resizeFocused(width isWidth: Bool, by delta: CGFloat) {
        let bounds = onScreenBounds()
        guard let window = focused(), let frame = bounds[window.id] else { return }
        if window.isFloating || !running {
            var resized = frame
            if isWidth { resized.size.width = max(160, frame.width + delta) } else { resized.size.height = max(100, frame.height + delta) }
            setFrame(window, resized)
            return
        }
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return }
        let screen = screens[screens.index(for: frame)]
        let tiled = tiledWindows(in: window.workspace, bounds: bounds)
        guard let position = tiled.firstIndex(where: { $0 === window }), tiled.count > 1 else { return }
        let area = area(of: screen)
        var state = state(for: screen.id)

        switch state.layout {
        case .tall, .wide:
            let splitIsHorizontal = state.layout == .tall
            if isWidth == splitIsHorizontal {
                // Across the master/stack split: the master grows, a stack window grows by shrinking it.
                let change = delta / (splitIsHorizontal ? area.width : area.height)
                state.ratio = min(0.9, max(0.1, state.ratio + (position == 0 ? change : -change)))
                screenStates[screen.id] = state
            } else {
                // Along the stack; the master always spans the whole length.
                guard position > 0, tiled.count > 2 else { return }
                let stack = Array(tiled.dropFirst())
                window.weight = Self.weight(at: position - 1, of: stack.map(\.weight), growingBy: delta,
                                            length: splitIsHorizontal ? area.height : area.width, gap: config.gap)
            }
        case .columns:
            guard var layout = columns[window.workspace], let (c, r) = layout.locate(window.id) else { return }
            if isWidth {
                let weights = layout.columns.map(\.weight)
                guard weights.count > 1 else { return }
                layout.setColumnWeight(c, Self.weight(at: c, of: weights, growingBy: delta, length: area.width, gap: config.gap))
                columns[window.workspace] = layout
            } else {
                let stack = layout.columns[c].windows.compactMap { windows[$0] }
                guard stack.count > 1 else { return }
                window.weight = Self.weight(at: r, of: stack.map(\.weight), growingBy: delta, length: area.height, gap: config.gap)
            }
        case .monocle:
            return
        }
        retile()
    }

    /// The new weight for item `index` so that it gains `delta` points along `length`,
    /// with the other items keeping their weights (and sharing the difference).
    static func weight(at index: Int, of weights: [CGFloat], growingBy delta: CGFloat, length: CGFloat, gap: CGFloat) -> CGFloat {
        let usable = length - gap * CGFloat(weights.count - 1)
        let total = weights.reduce(0, +)
        let others = total - weights[index]
        let minimum: CGFloat = 80
        let current = usable * weights[index] / total
        let target = min(usable - minimum * CGFloat(weights.count - 1), max(minimum, current + delta))
        return max(0.05, target * others / (usable - target))
    }

    func toggleFloat() {
        guard let window = focused() else { return }
        window.isFloating.toggle()
        window.userOverride = true
        if window.isFloating { focus(window) }
        scheduleRetile()
    }

    /// Moves the focused window into the workspace shown on the next display.
    func moveToNextDisplay() {
        let screens = ScreenInfo.current()
        guard screens.count > 1, let window = focused(), let frame = onScreenBounds()[window.id] else { return }
        syncDisplays()
        let next = screens[(screens.index(for: frame) + 1) % screens.count]
        if let workspace = displayed[next.id] { window.workspace = workspace }
        if window.isFloating || !running { setFrame(window, next.centered(frame.size)) }
        retile()
        focus(window)
        notifyWorkspace()
    }

    /// Moves the focused workspace, windows and arrangement, to the next display, where it
    /// replaces the workspace shown there (which stays intact, just hidden). The display it
    /// leaves goes back to the last of its own workspaces it showed, or to none.
    func moveWorkspaceToNextDisplay() {
        let screens = ScreenInfo.current()
        guard running, screens.count > 1, let source = focusedScreen(), let workspace = displayed[source.id],
              let sourceIndex = screens.firstIndex(where: { $0.id == source.id }) else { return }
        let target = screens[(sourceIndex + 1) % screens.count]
        ignoreFocusChanges()
        if let window = focused(), window.workspace == workspace { lastFocused[workspace] = window.id }

        homeOverride[workspace] = target.id
        show(workspace, on: target.id)
        let remaining = (0..<workspaceCount).filter { $0 != workspace && home(of: $0, screens)?.id == source.id }
        let back = shownBefore[source.id].flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.first
        show(back, on: source.id)
        log.debug("move workspace \(workspace) from display \(source.id) to \(target.id); display \(source.id) now shows \(back ?? -1)")
        retile()
        focusWindow(in: workspace)
        notifyWorkspace()
    }

    /// Focuses the workspace shown on the next display.
    func focusNextDisplay() {
        let screens = ScreenInfo.current()
        guard screens.count > 1, let current = focusedScreen(),
              let index = screens.firstIndex(where: { $0.id == current.id }) else { return }
        if let workspace = displayed[screens[(index + 1) % screens.count].id] { focusWindow(in: workspace) }
        notifyWorkspace()
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
            // Dropping a tiled window onto another one swaps them; dropping it on another
            // display moves it into the workspace shown there.
            if let target = visible(bounds, tiledOnly: true).first(where: { $0.0.id != id && $0.1.contains(point) }) {
                swapOrder(id, target.0.id)
                if window.workspace == target.0.workspace {
                    columns[window.workspace]?.swap(id, target.0.id)
                }
                window.workspace = target.0.workspace
            } else if let screen = ScreenInfo.current().first(where: { $0.frame.contains(point) }),
                      let workspace = displayed[screen.id] {
                window.workspace = workspace
            }
        case .resize:
            // Resizing a tiled window drags the master/stack split instead.
            let screens = ScreenInfo.current()
            guard let frame = bounds[id], !screens.isEmpty else { break }
            let screen = screens[screens.index(for: frame)]
            var state = state(for: screen.id)
            let isMaster = tiledWindows(in: window.workspace, bounds: bounds).first === window
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
