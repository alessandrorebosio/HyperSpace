import AppKit

struct ScreenState {
    var layout: LayoutKind
    var ratio: CGFloat

    /// The master area grows by `delta` (a share of the screen), within `TilingConfig.ratioRange`.
    mutating func adjustRatio(by delta: CGFloat) {
        ratio = (ratio + delta).clamped(to: TilingConfig.ratioRange)
    }
}

struct DragSession {
    let mode: DragMode
    let element: AXUIElement
    let pid: pid_t
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
    var onWorkspaceChange: ((WorkspaceBar?) -> Void)?
    /// Called when tiling is turned on or off by the toggle-tiling action.
    var onEnabledChange: ((Bool) -> Void)?
    /// Until then apps opened with a rule do not take you to their workspace: they are the
    /// apps macOS reopens at login, not ones you open. Set when HyperSpace starts at login.
    var revealAfter = Date.distantPast

    var running = false
    var apps: [pid_t: AppWatcher] = [:]
    var windows: [CGWindowID: ManagedWindow] = [:]
    /// The tracked windows of each app, to find the one an AX notification is about.
    var windowIDs: [pid_t: [CGWindowID]] = [:]
    /// Tiling order; the first window of each screen is the master.
    var order: [CGWindowID] = []
    /// Layout and ratio per display, by display UUID (they survive unplugging it).
    var screenStates: [String: ScreenState] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    /// Bursts of events become one retile, one focus lookup, one snap-back check, one save.
    private let retileCoalescer = Coalescer(delay: 0.03)
    private let focusCoalescer = Coalescer()
    private let snapBackCoalescer = Coalescer(delay: 0.15)
    let saveCoalescer = Coalescer(delay: 2)
    var drag: DragSession?
    /// Dragging writes to the app on its AX queue, one write at a time with only the latest
    /// point waiting; `dragGeneration` tells the writes of an old drag from the current one.
    var dragWriteInFlight = false
    var dragPendingPoint: CGPoint?
    var dragGeneration = 0
    /// The window under the pointer is being looked up (off the main thread) for a new drag;
    /// a release meanwhile is kept and played once it is found.
    var dragStarting = false
    var dragEndedEarly: CGPoint?
    /// Finds the window a drag starts on: an AX hit test that a hung app answers slowly.
    let dragLookup = DispatchQueue(label: "HyperSpace.dragLookup", qos: .userInteractive)
    lazy var refcon = Unmanaged.passUnretained(self).toOpaque()

    /// The workspace each display shows.
    var displayed: [CGDirectDisplayID: Int] = [:]
    /// Workspaces moved to another display than their default one, by display UUID (a
    /// monitor plugged in again may get another id).
    var homeOverride: [Int: String] = [:]
    /// What each display that went away (unplugged, asleep) showed, by UUID: shown again
    /// when it comes back.
    var departed: [String: Int] = [:]
    private let displayMonitor = DisplayMonitor()
    /// An invisible window of HyperSpace's own that takes the key focus on a display with
    /// nothing to focus, so macOS treats that display as the active one.
    lazy var focusAnchor = FocusAnchor()
    /// The app focused last, to bring dialogs forward only when their app comes to the front.
    private var lastFrontPID: pid_t?
    /// Each watched app's focused window (0: none), kept from its focus notifications so that
    /// commands need no AX round trip (see `readFocused`).
    var focusedIn: [pid_t: CGWindowID] = [:]
    /// Counts each app's focus notifications: a lookup started before a newer one is dropped.
    var focusEpoch: [pid_t: Int] = [:]
    /// The workspace each display showed before the current one.
    var shownBefore: [CGDirectDisplayID: Int] = [:]
    /// Column arrangement of each workspace (columns layout), accordions included.
    var columns: [Int: ColumnLayout] = [:]
    /// Workspaces stacked as an accordion on top of a tall, wide or monocle layout (in columns
    /// the accordion is a column of `ColumnLayout`).
    var accordionWorkspaces: Set<Int> = []
    var previousWorkspace: Int?
    var lastFocused: [Int: CGWindowID] = [:]
    /// Focus changes we cause ourselves must not switch workspace back.
    var followFocusAfter = Date.distantPast
    /// A window just moved to a hidden workspace that still has focus: it must not drag
    /// its workspace onto the screen. Cleared as soon as focus goes elsewhere.
    var movedAway: CGWindowID?
    /// The display the user works on, set when we move the focus there: an empty workspace
    /// has no window to tell, and the pointer may still be on the other display.
    var activeDisplay: CGDirectDisplayID?
    /// The display of an empty workspace holding the focus (the focus anchor is there): the
    /// display you work on, even while the window left behind still looks focused to macOS.
    var heldDisplay: CGDirectDisplayID?
    /// Last value sent to `onWorkspaceChange` (nil: none sent yet), so the menu bar is
    /// redrawn only on change.
    var lastNotice: WorkspaceBar??
    /// Workspaces apps were opened from, for the windows they show while loading.
    var launches = LaunchTracker()
    /// Running apps are being picked up at start: retile once they all are.
    private var adopting = false
    let axQueues = AXQueues()
    /// The workspaces saved last time, while the windows found at start are matched to them.
    var restorer: WorkspaceRestorer?
    var restoredState: WorkspaceState?
    var restoredIndex: [CGWindowID: Int] = [:]
    /// The last state written (its date left out), so an unchanged state is not written again.
    var lastSaved: WorkspaceState?
    let saveQueue = DispatchQueue(label: "HyperSpace.state", qos: .utility)
    /// The last problems talking to apps, for the debug report.
    var issues: [String] = []
    /// Apps opened for the scratchpad: their next window goes there (until the date).
    var pendingScratchpad: [String: Date] = [:]
    /// The size a scratchpad window took instead of the one asked for `target`.
    var scratchpadFitted: (target: CGRect, size: CGSize)?
    /// Window lookups still running on the apps' AX queues, and what waits for them.
    var pendingDiscoveries = 0
    var afterDiscoveries: [() -> Void] = []

    /// The tracked windows in tiling order.
    var orderedWindows: [ManagedWindow] { order.compactMap { windows[$0] } }

    /// The smallest size resizing by hand (a shortcut, a drag) takes a window to.
    static let minimumWindowSize = CGSize(width: 160, height: 100)
    /// The least length resizing by a shortcut leaves each of the other tiles of a split.
    static let minimumTileLength: CGFloat = 80

    /// At least one workspace per display, even when fewer are configured.
    var workspaceCount: Int { max(1, config.workspaces.count, NSScreen.screens.count) }

    func name(of workspace: Int) -> String {
        workspace < config.workspaces.count ? config.workspaces[workspace] : TilingConfig.workspaceName(nil, at: workspace)
    }

    /// Whether the rules make a window float: a dialog, or an app or title rule. The title (an
    /// AX read) is only asked for when a rule looks at titles.
    func shouldFloat(_ window: ManagedWindow, title: () -> String?) -> Bool {
        window.isDialog || config.floats(app: window.bundleID, title: config.floatingWindows.isEmpty ? nil : title())
    }

    // MARK: - What a command reads from the system, once

    /// The displays, the on-screen windows and the focused window cost a window-server query,
    /// several `NSScreen` reads and a synchronous AX round trip. A command (a shortcut, a
    /// notification) reads each at most once: between `enterScope` and `leaveScope` the first
    /// read is kept and every function the command calls shares it. Scopes nest, so a command
    /// calling another one stays in its own. Outside a scope every read is fresh.
    struct Scope {
        var screens: [ScreenInfo]?
        var bounds: [CGWindowID: CGRect]?
        var focusedRead = false
        var focused: ManagedWindow?
    }

    var scope: Scope?
    private var scopeDepth = 0

    func enterScope() {
        scopeDepth += 1
        if scopeDepth == 1 { scope = Scope() }
    }

    func leaveScope() {
        scopeDepth -= 1
        if scopeDepth == 0 { scope = nil }
    }

    func currentScreens() -> [ScreenInfo] {
        if let screens = scope?.screens { return screens }
        let screens = ScreenInfo.current()
        scope?.screens = screens
        return screens
    }

    func currentBounds() -> [CGWindowID: CGRect] {
        if let bounds = scope?.bounds { return bounds }
        let bounds = windowBounds()
        scope?.bounds = bounds
        return bounds
    }

    // MARK: - Lifecycle

    func apply(_ newConfig: TilingConfig) {
        if newConfig.layout != config.layout || newConfig.masterRatio != config.masterRatio {
            screenStates.removeAll()
        }
        // Titles are read over AX: only when the rules that decide floating changed.
        let rulesChanged = newConfig.floating != config.floating || newConfig.floatingWindows != config.floatingWindows
        config = newConfig
        if rulesChanged {
            for window in windows.values where !window.userOverride {
                window.isFloating = shouldFloat(window) { window.title }
            }
        }
        // Fewer workspaces than before: their windows join the first one.
        let count = workspaceCount
        displayed = displayed.filter { $0.value < count }
        // A pin in the config replaces a move made by hand.
        homeOverride = homeOverride.filter { $0.key < count && config.pins[$0.key] == nil }
        // A workspace on screen that was just pinned to another display goes there now.
        if running {
            let screens = currentScreens()
            for workspace in config.pins.keys.sorted() where workspace < count {
                guard let shownOn = display(showing: workspace), let pinned = pinnedDisplay(of: workspace, screens),
                      pinned.id != shownOn else { continue }
                displayed[shownOn] = nil
                showWorkspace(workspace, on: pinned.id)
                carryFloating(windows.values.filter { $0.workspace == workspace }, screens: screens)
            }
        }
        accordionWorkspaces = accordionWorkspaces.filter { $0 < count }
        shownBefore = shownBefore.filter { $0.value < count }
        if let previous = previousWorkspace, previous >= count { previousWorkspace = nil }
        for window in windows.values where window.workspace >= count { window.workspace = 0 }
        columns = columns.filter { $0.key < count }
        lastFocused = lastFocused.filter { $0.key < count }
        config.enabled ? start() : stop()
        notifyWorkspace()
        scheduleRetile()
    }

    func toggleEnabled() {
        config.enabled.toggle()
        config.enabled ? start() : stop()
        onEnabledChange?(config.enabled)
        scheduleRetile()
    }

    /// Puts every parked window back where it was (on quit).
    func restoreHiddenWindows() {
        for window in windows.values {
            guard let frame = window.hiddenFrame else { continue }
            setFrame(window, frame)
            window.hiddenFrame = nil
        }
        axQueues.flush(timeout: 1.5)
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
            noteLaunch(app)
            addApp(app)
            lookAgainAfterLaunch(app.processIdentifier)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            launches.forget(app.processIdentifier)
            removeApp(app.processIdentifier)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            // Windows living on other Spaces are only listed by AX once visible.
            guard let self, let app else { return }
            // An app being opened activates before macOS reports it launched (that comes once
            // it finished launching, for some apps after their first window).
            noteLaunch(app)
            if let watcher = apps[app.processIdentifier] {
                discover(watcher)
                refreshFocused(app.processIdentifier)
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
        ) { [weak self] _ in self?.displaysChanged() }
        displayMonitor.onChange = { [weak self] in self?.displaysChanged() }
        displayMonitor.start()

        // Window elements use the global AX timeout (6 s by default): an app still busy
        // launching at login must not stall the window manager that long.
        _ = AX.systemWide
        focusAnchor.onResign = { [weak self] in
            guard let self else { return }
            heldDisplay = nil
            scheduleFocusUpdate()
        }
        loadSavedState()
        syncDisplays()
        // One app per run loop turn, the frontmost first: shortcuts stay responsive while
        // apps that are slow to answer (at login) are adopted, and the screen tiles once.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pending = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.processIdentifier == frontmost ? 0 : 1) < ($1.processIdentifier == frontmost ? 0 : 1) }
        adopting = true
        adopt(pending[...])
        // Right after a login or a WindowServer restart, or on a busy Mac, apps can answer AX
        // with placeholder elements: look again once they have settled.
        DispatchQueue.main.asyncAfter(delays: [2, 6]) { [weak self] in self?.rescan() }
    }

    private func displaysChanged() {
        // The focused window of the removed display moving must not switch workspaces.
        ignoreFocusChanges()
        syncDisplays()
        scheduleRetile()
        // macOS relocates the windows of the removed display a moment after the notification.
        DispatchQueue.main.asyncAfter(delays: [0.5, 1.5]) { [weak self] in self?.scheduleRetile() }
        notifyWorkspace()
    }

    /// Some apps create their first window before AX describes it (no subrole yet) or without
    /// announcing it: look again a few times, so an app with a rule goes to its workspace
    /// right away instead of when it is focused.
    private func lookAgainAfterLaunch(_ pid: pid_t) {
        DispatchQueue.main.asyncAfter(delays: [0.5, 1.5, 3, 6]) { [weak self] in
            guard let self, let watcher = apps[pid] else { return }
            discover(watcher)
        }
    }

    /// Remembers the workspace an app is being opened from, the first time it is seen.
    private func noteLaunch(_ app: NSRunningApplication) {
        enterScope()
        defer { leaveScope() }
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, !launches.contains(pid),
              app.launchDate.map({ Date().timeIntervalSince($0) < 30 }) ?? !app.isFinishedLaunching,
              !windows.values.contains(where: { $0.pid == pid }),
              let workspace = focusedWorkspace else { return }
        log.debug("launch of \(app.bundleIdentifier ?? "?", privacy: .public) from workspace \(workspace)")
        launches.launched(pid, in: workspace)
    }

    private func adopt(_ pending: ArraySlice<NSRunningApplication>) {
        guard running else { return }
        guard let app = pending.first else {
            // Once every window found has been looked at (AX answers come back asynchronously).
            whenDiscovered { [weak self] in
                guard let self, running, adopting else { return }
                adopting = false
                applyRestoredLayout()
                rescueStrandedWindows()
                scheduleRetile()
            }
            return
        }
        addApp(app)
        DispatchQueue.main.async { [weak self] in self?.adopt(pending.dropFirst()) }
    }

    private func stop() {
        guard running else { return }
        restoreHiddenWindows()
        running = false
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        displayMonitor.onChange = nil
        displayMonitor.stop()
        releaseHeldFocus()
        apps.values.forEach { $0.invalidate() }
        apps.removeAll()
        launches.removeAll()
        adopting = false
        windows.removeAll()
        windowIDs.removeAll()
        order.removeAll()
        lastFocused.removeAll()
        displayed.removeAll()
        homeOverride.removeAll()
        departed.removeAll()
        shownBefore.removeAll()
        activeDisplay = nil
        lastFrontPID = nil
        focusedIn.removeAll()
        focusEpoch.removeAll()
        pendingDiscoveries = 0
        afterDiscoveries.removeAll()
    }

    /// After a crash windows can be left parked off-screen: bring them back.
    private func rescueStrandedWindows() {
        let screens = currentScreens()
        guard let main = screens.first else { return }
        for (id, frame) in currentBounds() {
            guard let window = windows[id], Self.isParked(frame, on: screens) else { continue }
            setFrame(window, main.centered(frame.size))
        }
    }

    // MARK: - Layout

    /// Coalesces bursts of events (an app opening five windows) into one retile.
    func scheduleRetile() {
        guard running, !adopting else { return }
        retileCoalescer.schedule { [weak self] in self?.retile() }
    }

    /// An app activation and its focused-window change arrive together: one lookup for both.
    func scheduleFocusUpdate() {
        guard running else { return }
        focusCoalescer.schedule { [weak self] in
            guard let self else { return }
            enterScope()
            defer { leaveScope() }
            let window = focused()
            if let window, window.pid != lastFrontPID {
                // Its app came to the front (⌘Tab, a click, the Dock): its dialogs come along.
                let dialogs = dialogs(of: window)
                if !dialogs.isEmpty { axQueues.perform(window.pid) { dialogs.forEach(AX.raise) } }
            }
            lastFrontPID = window?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            followFocus(window)
            notifyWorkspace(focused: window)
        }
    }

    /// Retiles once no mouse button is held (the user may still be dragging the window).
    func scheduleSnapBack() {
        guard running else { return }
        snapBackCoalescer.schedule { [weak self] in
            guard let self else { return }
            // Still held: look again a moment later.
            if NSEvent.pressedMouseButtons != 0 { return scheduleSnapBack() }
            scheduleRetile()
        }
    }

    func retile() {
        guard running, config.enabled, drag == nil, !dragStarting else { return }
        enterScope()
        defer { leaveScope() }
        syncDisplays()
        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        let bounds = currentBounds()
        let shown = Set(displayed.values)
        let tiledByWorkspace = Dictionary(grouping: orderedWindows.filter { Self.isTiled($0, bounds: bounds) }, by: \.workspace)

        for window in windows.values {
            if let owner = window.parent.flatMap({ windows[$0] }), owner.scratchpad {
                // A dialog of a scratchpad window comes and goes with it.
                if !owner.scratchpadShown {
                    parkOrKeepHidden(window, bounds: bounds, screens: screens)
                } else if let frame = bounds[owner.id], let screen = screens.screen(for: frame) {
                    restore(window, on: screen, screens)
                }
                continue
            }
            if window.scratchpad {
                // Out of the workspaces: parked unless shown.
                if !window.scratchpadShown { parkOrKeepHidden(window, bounds: bounds, screens: screens) }
                continue
            }
            if !shown.contains(window.workspace) {
                parkOrKeepHidden(window, bounds: bounds, screens: screens)
            } else if window.isFloating, let screen = screens.first(where: { displayed[$0.id] == window.workspace }) {
                restore(window, on: screen, screens)
            }
        }

        for screen in screens {
            guard let workspace = displayed[screen.id] else { continue }
            let tiled = (tiledByWorkspace[workspace] ?? []).filter { window in
                // A native full-screen window covers the whole display, menu bar included.
                window.hiddenFrame != nil || !screens.contains { bounds[window.id]!.isClose(to: $0.frame) }
            }
            guard !tiled.isEmpty else { continue }
            let state = state(for: screen.id)
            log.debug("retile display \(screen.id) workspace \(workspace): \(tiled.count) tiled \(tiled.map { $0.bundleID ?? "?" }, privacy: .public)")
            let frames: [CGWindowID: CGRect]
            if state.layout == .columns {
                var layout = columns[workspace] ?? ColumnLayout()
                layout.sync(with: tiled.map(\.id), focused: lastFocused[workspace])
                columns[workspace] = layout
                frames = layout.frames(in: area(of: screen), gap: config.gap, peek: config.accordionPadding) { windows[$0]?.weight ?? 1 }
            } else {
                let focusedIndex = tiled.firstIndex { $0.id == lastFocused[workspace] } ?? 0
                let kind = accordionWorkspaces.contains(workspace) ? .accordion : state.layout
                let list = Layout.frames(kind, weights: tiled.map(\.weight), in: area(of: screen),
                                         gap: config.gap, ratio: state.ratio, focused: focusedIndex, peek: config.accordionPadding)
                frames = Dictionary(uniqueKeysWithValues: zip(tiled.map(\.id), list))
            }
            for window in tiled {
                guard let frame = frames[window.id] else { continue }
                window.hiddenFrame = nil
                if !(bounds[window.id]?.isClose(to: frame, tolerance: 1) ?? false) { setFrame(window, frame, from: bounds[window.id], screens: screens) }
            }
        }
        scheduleSave()
    }

    /// The display's visible frame (no menu bar, no Dock) less the padding: every layout
    /// works inside it, never in absolute screen coordinates of its own.
    func area(of screen: ScreenInfo) -> CGRect {
        let area = screen.visible.insetBy(dx: config.padding, dy: config.padding)
        return area.width > 0 && area.height > 0 ? area : screen.visible
    }

    /// Tiled windows of a workspace that are on screen, in tiling order.
    func tiledWindows(in workspace: Int, bounds: [CGWindowID: CGRect]) -> [ManagedWindow] {
        orderedWindows.filter { $0.workspace == workspace && Self.isTiled($0, bounds: bounds) }
    }

    private static func isTiled(_ window: ManagedWindow, bounds: [CGWindowID: CGRect]) -> Bool {
        !window.isFloating && !window.scratchpad && bounds[window.id] != nil
    }

    /// Counts focus requests, so a retry of an old one gives up.
    var focusRequest = 0

    /// Focus changes in the next moment come from us (hiding windows makes apps refocus),
    /// not from the user, and must not switch workspaces.
    func ignoreFocusChanges() {
        followFocusAfter = Date().addingTimeInterval(0.6)
    }

    /// Focuses a window without the resulting focus change switching workspaces. Crossing
    /// to another display brings the pointer along (if enabled), and as macOS sometimes
    /// ignores a background app raising a window on another display, it checks and retries.
    /// `frame` is where the window is going, when we just moved it (the move is not done yet).
    func focus(_ window: ManagedWindow, at frame: CGRect? = nil) {
        enterScope()
        defer { leaveScope() }
        ignoreFocusChanges()
        focusRequest += 1
        let request = focusRequest
        releaseHeldFocus()
        let dialogs = dialogs(of: window)
        axQueues.perform(window.pid) {
            AX.focus(window.element, pid: window.pid)
            dialogs.forEach(AX.raise)
        }
        lastFrontPID = window.pid
        let screens = currentScreens()
        if let frame = frame ?? currentBounds()[window.id], let screen = screens.screen(for: frame) {
            activeDisplay = screen.id
            bringPointer(to: frame.center, on: screen)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // A later focus (another workspace, keys pressed in a row) wins over this retry.
            guard let self, focusRequest == request,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
            note("focus did not take for \(window.bundleID ?? "?") window \(window.id), retrying")
            ignoreFocusChanges()
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
            axQueues.perform(window.pid) { AX.focus(window.element, pid: window.pid) }
        }
    }

    /// The dialogs of a window: they share its workspace and come and go with it.
    func dialogWindows(of window: ManagedWindow) -> [ManagedWindow] {
        windows.values.filter { $0.parent == window.id }
    }

    /// The dialogs of a window that are on screen: they come to the front with it.
    private func dialogs(of window: ManagedWindow) -> [AXUIElement] {
        dialogWindows(of: window).filter { $0.hiddenFrame == nil && !$0.scratchpad }.map(\.element)
    }

    /// Moves the pointer to `point` when it is on another display than `screen`.
    func bringPointer(to point: CGPoint, on screen: ScreenInfo) {
        guard config.mouseFollowsFocus, !screen.frame.contains(Pointer.location) else { return }
        Pointer.warp(to: point)
    }

    /// `current`, when known, lets a move within a display skip the writes it does not need.
    func setFrame(_ window: ManagedWindow, _ frame: CGRect, from current: CGRect? = nil, screens: [ScreenInfo]? = nil) {
        window.movedByUs = Date()
        let sameDisplay = current.map { Self.sameDisplay($0, frame, screens ?? currentScreens()) } ?? false
        let steps = Self.frameSteps(from: current, to: frame, sameDisplay: sameDisplay)
        guard !steps.isEmpty else { return }
        let app = apps[window.pid]?.element
        let element = window.element
        let name = window.bundleID ?? "?"
        axQueues.perform(window.pid) { [weak self] in
            // AXEnhancedUserInterface (set by VoiceOver-aware tools) makes some apps
            // animate every AX resize; switch it off while we move the window.
            let enhanced = app.flatMap { AX.bool($0, "AXEnhancedUserInterface") } ?? false
            if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", false) }
            var failure = AXError.success
            for step in steps {
                let result: AXError
                switch step {
                case .size: result = AX.setSize(element, frame.size)
                case .position: result = AX.setPosition(element, frame.origin)
                }
                if result != .success { failure = result }
            }
            // Across displays some apps answer the move with a size of their own (kept from
            // the old display, or clamped to it): once more, now that it is on the new one.
            if !sameDisplay, failure == .success, let actual = AX.frame(element), !actual.isClose(to: frame, tolerance: 1) {
                AX.setPosition(element, frame.origin)
                AX.setSize(element, frame.size)
            }
            if failure != .success {
                DispatchQueue.main.async { self?.note("moving a window of \(name) failed: AX error \(failure.rawValue)") }
            }
            if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", true) }
        }
        // Others resize themselves a moment later, for the scale of the new display; that
        // resize comes too soon to count as the user's, so look again once it is done.
        if current != nil, !sameDisplay, !window.isFloating, !window.scratchpad {
            DispatchQueue.main.asyncAfter(delays: [0.3, 0.8]) { [weak self] in self?.scheduleRetile() }
        }
    }

    enum FrameStep { case size, position }

    /// The AX writes that take a window from `current` to `target`. Across displays (or from
    /// an unknown frame): size → position → size, the first resize lets the window fit on
    /// the destination display, the second fixes apps that clamp to the old screen. Within a
    /// display only what changed, shrinking before moving so the window never sticks out.
    static func frameSteps(from current: CGRect?, to target: CGRect, sameDisplay: Bool) -> [FrameStep] {
        guard let current, sameDisplay else { return [.size, .position, .size] }
        let sizeChanges = !current.size.isClose(to: target.size, tolerance: 1)
        let originChanges = !current.origin.isClose(to: target.origin, tolerance: 1)
        switch (sizeChanges, originChanges) {
        case (false, false): return []
        case (true, false): return [.size]
        case (false, true): return [.position]
        case (true, true):
            let grows = target.width > current.width + 1 || target.height > current.height + 1
            return grows ? [.position, .size] : [.size, .position]
        }
    }

    private static func sameDisplay(_ a: CGRect, _ b: CGRect, _ screens: [ScreenInfo]) -> Bool {
        !screens.isEmpty && screens.index(for: a) == screens.index(for: b)
    }

    /// Visible, normal-layer windows on the current Space with their frames.
    private func windowBounds() -> [CGWindowID: CGRect] {
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

    func state(for screen: CGDirectDisplayID?) -> ScreenState {
        screen.flatMap { screenStates[ScreenInfo.uuid(of: $0)] } ?? ScreenState(layout: config.layout, ratio: config.masterRatio)
    }

    func setState(_ state: ScreenState, for screen: CGDirectDisplayID) {
        screenStates[ScreenInfo.uuid(of: screen)] = state
    }

    func updateActiveScreen(_ change: (inout ScreenState) -> Void) {
        enterScope()
        defer { leaveScope() }
        guard let id = focusedScreen()?.id else { return }
        var state = state(for: id)
        change(&state)
        setState(state, for: id)
        scheduleRetile()
    }
}
