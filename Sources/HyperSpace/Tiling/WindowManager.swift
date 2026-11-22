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
/// - Window lifecycle comes from AX observers and NSWorkspace notifications; the only poll
///   is `DisplayMonitor`'s, every few seconds, for displays asleep or on another input.
/// - Which windows are visible (current Space, not minimized, app not hidden) and where
///   they are is read from one `CGWindowListCopyWindowInfo` call per retile, which needs
///   no Screen Recording permission as long as window titles are not requested.
/// - Frames are only written when they differ from the target, so a retile with
///   nothing to do costs a single window-server query.
/// - Workspaces are virtual (macOS offers no public API to drive Spaces). Each one lives on
///   a display: workspace 1 the main display, 2 the second, and so on, the rest on the
///   main display, until moved to another display. Each display shows one of its
///   workspaces (or none when all of them were moved away). Every window belongs
///   to a workspace; windows of workspaces not shown are parked in a bottom corner of
///   their screen (the one with no other display beyond it).
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
    private let retileCoalescer = Coalescer(delay: Delay.retile)
    let focusCoalescer = Coalescer()
    private let snapBackCoalescer = Coalescer(delay: Delay.snapBackCheck)
    let saveCoalescer = Coalescer(delay: Delay.save)
    /// The modifier-drag in progress (see `DragState`).
    var dragState = DragState()
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
    let displayMonitor = DisplayMonitor()
    /// Clicks the desktop of a display with nothing to focus, so macOS makes it the active one.
    lazy var focusAnchor = FocusAnchor()
    /// Who has the focus and where the user works (see `FocusState`).
    var focusState = FocusState()
    /// The workspace each display showed before the current one.
    var shownBefore: [CGDirectDisplayID: Int] = [:]
    /// Column arrangement of each workspace (columns layout), accordions included.
    var columns: [Int: ColumnLayout] = [:]
    /// Workspaces stacked as an accordion on top of a tall, wide or monocle layout (in columns
    /// the accordion is a column of `ColumnLayout`).
    var accordionWorkspaces: Set<Int> = []
    var previousWorkspace: Int?
    /// Last value sent to `onWorkspaceChange` (nil: none sent yet), so the menu bar is
    /// redrawn only on change.
    var lastNotice: WorkspaceBar??
    /// Workspaces apps were opened from, for the windows they show while loading.
    var launches = LaunchTracker()
    let axQueues = AXQueues()
    /// Matching the windows found to the workspaces saved last time (see `RestoreSession`).
    var restoreSession = RestoreSession()
    /// The last state written (its date left out), so an unchanged state is not written again.
    var lastSaved: WorkspaceState?
    let saveQueue = DispatchQueue(label: "HyperSpace.state", qos: .utility)
    /// The last problems talking to apps, for the debug report.
    var issues: [String] = []
    /// Apps opened for the scratchpad: their next window goes there (until the date).
    var pendingScratchpad: [String: Date] = [:]
    /// The size a scratchpad window took instead of the one asked for `target`.
    var scratchpadFitted: (target: CGRect, size: CGSize)?
    /// The looks for windows in flight and the run they belong to (see `DiscoveryState`).
    var discovery = DiscoveryState()

    /// The tracked windows in tiling order.
    var orderedWindows: [ManagedWindow] { order.compactMap { windows[$0] } }

    /// The smallest size resizing by hand (a shortcut, a drag) takes a window to.
    static let minimumWindowSize = CGSize(width: 160, height: 100)
    /// The least length resizing by a shortcut leaves each of the other tiles of a split.
    static let minimumTileLength: CGFloat = 80
    /// How far (in points) a frame may be from its target and still count as there.
    static let frameTolerance: CGFloat = 1
    /// The same for frames that only have to be told apart roughly (a window covering a whole
    /// display, a floating window already where it should be).
    static let looseTolerance: CGFloat = 2
    /// For this long after we move a window, the moves it reports are ours (or the app's
    /// answer to ours), not the user's.
    static let ownMoveSettle: TimeInterval = 0.5
    /// How long the displays read last are good for outside a command: bursts of events (every
    /// focus change asks) read them once. A display change drops them at once; this only
    /// bounds how late a change with no notification (the Dock resized) is seen.
    static let screensLifetime: TimeInterval = 1

    /// How many times an app that cannot be watched yet (still launching) is tried again.
    static let watchAttempts = 20
    /// How many times a window AX does not describe yet is looked at again.
    static let describeAttempts = 5

    /// The waits of the window manager, in seconds.
    enum Delay {
        /// Bursts of events become one retile.
        static let retile: TimeInterval = 0.03
        /// Between two looks at the mouse buttons while a window moved by hand is still held.
        static let snapBackCheck: TimeInterval = 0.15
        /// From a change to writing the state.
        static let save: TimeInterval = 2
        /// Focus changes for this long after we move the focus or hide windows are ours.
        static let focusIgnore: TimeInterval = 0.6
        /// An app that has not come to the front by then is activated and focused once more.
        static let focusRetry: TimeInterval = 0.15
        /// Some apps put a new window on screen a moment after announcing it.
        static let newWindowSettle: TimeInterval = 0.25
        /// Apps resize themselves for the new display's scale a moment after a move across displays.
        static let crossDisplaySettle: [TimeInterval] = [0.3, 0.8]
        /// macOS relocates the windows of a removed display a moment after saying it is gone.
        static let displayChangeSettle: [TimeInterval] = [0.5, 1.5]
        /// The looks for the windows of an app just launched.
        static let launchLooks: [TimeInterval] = [0.5, 1.5, 3, 6]
        /// The rescans after a start, once apps answering with placeholders have settled.
        static let startRescans: [TimeInterval] = [2, 6]
        /// From showing the workspace of an app just opened to focusing its window there.
        static let revealFocus: TimeInterval = 0.3
        /// The longest the window lookups in flight are waited for.
        static let discoveryTimeout: TimeInterval = 3
        /// Between two tries at watching an app.
        static let watchRetry: TimeInterval = 0.5
        /// The first wait for a window AX does not describe yet; doubled each time.
        static let describeRetry: TimeInterval = 0.2
        /// How long windows found after a start are matched to the saved workspaces.
        static let restoreWindow: TimeInterval = 60
        /// How long the next window of an app opened for the scratchpad goes there.
        static let scratchpadLaunch: TimeInterval = 30
        /// Before asking a scratchpad window once more for the size it missed.
        static let scratchpadRefit: TimeInterval = 0.1
    }

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
    /// notification) reads each at most once: inside `scoped` the first
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

    /// Runs `body` in a command scope: the displays, window bounds and focused window are read
    /// at most once for it, however many times it asks. Scopes nest; the outermost one ends them.
    func scoped(_ body: () -> Void) {
        scopedValue(body)
    }

    /// `scoped` for a body that returns a value.
    func scopedValue<T>(_ body: () -> T) -> T {
        scopeDepth += 1
        if scopeDepth == 1 { scope = Scope() }
        defer {
            scopeDepth -= 1
            if scopeDepth == 0 { scope = nil }
        }
        return body()
    }

    func currentScreens() -> [ScreenInfo] {
        if let screens = scope?.screens { return screens }
        let now = ProcessInfo.processInfo.systemUptime
        let screens: [ScreenInfo]
        // Only while running: stopped, nothing tells when the displays change.
        if running, let read = screensRead, now - read.at < Self.screensLifetime {
            screens = read.screens
        } else {
            screens = ScreenInfo.current(leavingOut: displayMonitor.absent)
            screensRead = running ? (screens, now) : nil
        }
        scope?.screens = screens
        return screens
    }

    /// The displays as read last and when (see `screensLifetime`); nil after a display change.
    var screensRead: (screens: [ScreenInfo], at: TimeInterval)?

    func currentBounds() -> [CGWindowID: CGRect] {
        if let bounds = scope?.bounds { return bounds }
        let bounds = windowBounds()
        scope?.bounds = bounds
        return bounds
    }

    // MARK: - Lifecycle

    func apply(_ newConfig: TilingConfig) {
        // A reload that changed only other sections (a remap, a binding), with tiling already
        // in the state asked for: nothing to redo.
        if newConfig == config, running == config.enabled { return }
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
        fitWorkspaces(to: count)
        // A pin in the config replaces a move made by hand.
        homeOverride = homeOverride.filter { config.pins[$0.key] == nil }
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
        config.enabled ? start() : stop()
        // A display left with a workspace that is gone, or just moved to its pin, shows its
        // next one: before the menu bar is told.
        if running { syncDisplays() }
        notifyWorkspace()
        scheduleRetile()
    }

    /// Tiling on or off until the next config load (when the file cannot be written).
    func setEnabled(_ on: Bool) {
        guard config.enabled != on else { return }
        config.enabled = on
        config.enabled ? start() : stop()
        onEnabledChange?(config.enabled)
        notifyWorkspace()
        scheduleRetile()
    }

    private func start() {
        guard !running else { return }
        running = true
        screensRead = nil
        // Apps that quit while tiling was off were never forgotten.
        axQueues.prune(keeping: Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)))

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
                // (The look also reads its focused window, as `refreshFocused` would.)
                discover(watcher)
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
        discovery.windowsAtStart = WindowList.allIDs()
        loadSavedState()
        syncDisplays()
        // One app per run loop turn, the frontmost first: shortcuts stay responsive while
        // apps that are slow to answer (at login) are adopted, and the screen tiles once.
        let frontmost = frontmostPID
        let pending = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.processIdentifier == frontmost ? 0 : 1) < ($1.processIdentifier == frontmost ? 0 : 1) }
        discovery.adopting = true
        adopt(pending[...], run: discovery.run)
        // Right after a login or a WindowServer restart, or on a busy Mac, apps can answer AX
        // with placeholder elements: look again once they have settled.
        DispatchQueue.main.asyncAfter(delays: Delay.startRescans) { [weak self] in self?.rescan() }
    }

    /// Some apps create their first window before AX describes it (no subrole yet) or without
    /// announcing it: look again a few times, so an app with a rule goes to its workspace
    /// right away instead of when it is focused.
    private func lookAgainAfterLaunch(_ pid: pid_t) {
        DispatchQueue.main.asyncAfter(delays: Delay.launchLooks) { [weak self] in
            guard let self, let watcher = apps[pid] else { return }
            discover(watcher)
        }
    }

    /// Remembers the workspace an app is being opened from, the first time it is seen.
    private func noteLaunch(_ app: NSRunningApplication) {
        scoped {
            let pid = app.processIdentifier
            guard app.activationPolicy == .regular, !launches.contains(pid),
                  app.launchDate.map({ Date().timeIntervalSince($0) < 30 }) ?? !app.isFinishedLaunching,
                  !windows.values.contains(where: { $0.pid == pid }),
                  let workspace = focusedWorkspace else { return }
            log.debug("launch of \(app.bundleIdentifier ?? "?", privacy: .public) from workspace \(workspace)")
            launches.launched(pid, in: workspace)
        }
    }

    /// `run` is the run (`discovery.run`) these apps belong to: tiling turned off and on
    /// meanwhile starts over, and what is left of this pass is dropped.
    private func adopt(_ pending: ArraySlice<NSRunningApplication>, run: Int) {
        guard running, run == discovery.run else { return }
        guard let app = pending.first else {
            // Once every window found has been looked at (AX answers come back asynchronously).
            whenDiscovered { [weak self] in
                guard let self, running, discovery.adopting else { return }
                discovery.adopting = false
                applyRestoredLayout()
                rescueStrandedWindows()
                scheduleRetile()
            }
            return
        }
        addApp(app)
        DispatchQueue.main.async { [weak self] in self?.adopt(pending.dropFirst(), run: run) }
    }

    private func stop() {
        guard running else { return }
        restoreHiddenWindows(waitUntilDone: false)
        running = false
        screensRead = nil
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
        windows.removeAll()
        windowIDs.removeAll()
        order.removeAll()
        displayed.removeAll()
        homeOverride.removeAll()
        departed.removeAll()
        shownBefore.removeAll()
        // Nothing of this run may leak into the next start (which loads the saved state again).
        // Each of these starts over as a whole, so no part of it can be missed; the counters
        // go on, so that what is still in flight (lookups, a restore's timer, a drag's writes,
        // a focus retry) is told from the next run's and dropped.
        focusState = FocusState(request: focusState.request)
        discovery = DiscoveryState(run: discovery.run + 1)
        restoreSession = RestoreSession(generation: restoreSession.generation + 1)
        dragState = DragState(generation: dragState.generation + 1)
        lastSaved = nil
        columns.removeAll()
        accordionWorkspaces.removeAll()
        screenStates.removeAll()
        previousWorkspace = nil
        lastNotice = nil
        pendingScratchpad.removeAll()
        scratchpadFitted = nil
    }

    // MARK: - Where a window belongs

    /// Where a window lives: in the scratchpad (a scratchpad window, or a dialog of one, which
    /// comes and goes with it), or in its workspace. Every "is it shown, is it tiled" question
    /// starts here, so scratchpad windows and their dialogs are never taken for workspace members.
    enum Placement: Equatable {
        case scratchpad(shown: Bool)
        case workspace(Int)
    }

    func placement(of window: ManagedWindow) -> Placement {
        if let owner = scratchpadOwner(of: window) { return .scratchpad(shown: owner.scratchpadShown) }
        if window.scratchpad { return .scratchpad(shown: window.scratchpadShown) }
        return .workspace(window.workspace)
    }

    /// The scratchpad window a dialog belongs to, if it belongs to one: it comes and goes with it.
    func scratchpadOwner(of window: ManagedWindow) -> ManagedWindow? {
        guard let owner = window.parent.flatMap({ windows[$0] }), owner.scratchpad else { return nil }
        return owner
    }

    /// Whether a window belongs to the windows of `workspace` (tiled or floating), not to the scratchpad.
    func isMember(_ window: ManagedWindow, of workspace: Int) -> Bool {
        placement(of: window) == .workspace(workspace)
    }

    /// Whether a window should be in view now: a shown scratchpad window (or a dialog of one),
    /// or a window of a workspace in `shown` (the displayed ones). Parked or not.
    func belongsOnScreen(_ window: ManagedWindow, shown: Set<Int>) -> Bool {
        switch placement(of: window) {
        case .scratchpad(let isShown): return isShown
        case .workspace(let workspace): return shown.contains(workspace)
        }
    }

    /// Whether a window takes a tile in its workspace: neither floating nor in the scratchpad.
    func takesTile(_ window: ManagedWindow) -> Bool {
        guard !window.isFloating, case .workspace = placement(of: window) else { return false }
        return true
    }

    /// A window taking a tile that is on screen (not minimized, its app not hidden, on this Space).
    func isTiled(_ window: ManagedWindow, bounds: [CGWindowID: CGRect]) -> Bool {
        takesTile(window) && bounds[window.id] != nil
    }

    /// Tiled windows of a workspace that are on screen, in tiling order.
    func tiledWindows(in workspace: Int, bounds: [CGWindowID: CGRect]) -> [ManagedWindow] {
        orderedWindows.filter { $0.workspace == workspace && isTiled($0, bounds: bounds) }
    }

    /// Windows taking a tile in a workspace, on screen or not (minimized, app hidden, another
    /// Space), in tiling order: they keep their column while out of sight.
    func tileMembers(of workspace: Int) -> [ManagedWindow] {
        orderedWindows.filter { $0.workspace == workspace && takesTile($0) }
    }

    /// The app in front, if any.
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    // MARK: - Layout

    /// Retiles now and again after each of `delays` (apps that settle a moment later).
    func scheduleRetile(after delays: [TimeInterval]) {
        scheduleRetile()
        DispatchQueue.main.asyncAfter(delays: delays) { [weak self] in self?.scheduleRetile() }
    }

    /// Coalesces bursts of events (an app opening five windows) into one retile.
    func scheduleRetile() {
        guard running, !discovery.adopting else { return }
        retileCoalescer.schedule { [weak self] in self?.retile() }
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
        guard running, config.enabled, dragState.session == nil, !dragState.starting else { return }
        scoped {
            syncDisplays()
            let screens = currentScreens()
            guard !screens.isEmpty else { return }
            let bounds = currentBounds()
            let shown = Set(displayed.values)

            for window in windows.values {
                switch placement(of: window) {
                case .scratchpad(shown: false):
                    // Out of the workspaces, and its dialogs with it: parked unless shown.
                    parkOrKeepHidden(window, bounds: bounds, screens: screens)
                case .scratchpad(shown: true):
                    // A dialog of a shown scratchpad window comes back with it (the window
                    // itself is placed by `showScratchpad`).
                    if let owner = scratchpadOwner(of: window), let frame = bounds[owner.id],
                       let screen = screens.screen(for: frame) {
                        restore(window, on: screen, screens, from: bounds[window.id])
                    }
                case .workspace(let workspace):
                    if !shown.contains(workspace) {
                        parkOrKeepHidden(window, bounds: bounds, screens: screens)
                    } else if window.isFloating, let id = display(showing: workspace), let screen = screens.first(id: id) {
                        if window.hiddenFrame != nil {
                            restore(window, on: screen, screens, from: bounds[window.id])
                        } else if let frame = bounds[window.id], !window.movedByUsRecently, Self.isOutOfSight(frame, on: screens) {
                            // On a display that is left out (asleep, on another input) or gone,
                            // where nothing brings it back: to the display showing its workspace.
                            setFrame(window, screen.centered(frame.size))
                        }
                    }
                }
            }

            let membersByWorkspace = Dictionary(grouping: orderedWindows.filter(takesTile), by: \.workspace)
            let displays = screens.map { (frame: $0.frame, area: area(of: $0)) }
            for screen in screens {
                guard let workspace = displayed[screen.id] else { continue }
                let members = membersByWorkspace[workspace] ?? []
                let tiled = members.filter { window in
                    guard let frame = bounds[window.id] else { return false }
                    return window.hiddenFrame != nil || !Self.isFullScreen(frame, displays: displays)
                }
                let state = state(for: screen.id)
                if state.layout == .columns {
                    // Every member keeps its place, on screen or not (minimized, its app hidden,
                    // full screen, another Space): it comes back where it was.
                    var layout = columns[workspace] ?? ColumnLayout()
                    layout.sync(with: members.map(\.id), focused: focusState.lastFocused[workspace])
                    columns[workspace] = layout
                }
                guard !tiled.isEmpty else { continue }
                log.debug("retile display \(screen.id) workspace \(workspace): \(tiled.count) tiled \(tiled.map(\.appLabel), privacy: .public)")
                let frames: [CGWindowID: CGRect]
                if state.layout == .columns {
                    frames = (columns[workspace] ?? ColumnLayout()).restricted(to: Set(tiled.map(\.id)))
                        .frames(in: area(of: screen), gap: config.gap, peek: config.accordionPadding) { windows[$0]?.weight ?? 1 }
                } else {
                    let focusedIndex = tiled.firstIndex { $0.id == focusState.lastFocused[workspace] } ?? 0
                    let kind = accordionWorkspaces.contains(workspace) ? .accordion : state.layout
                    let list = Layout.frames(kind, weights: tiled.map(\.weight), in: area(of: screen),
                                             gap: config.gap, ratio: state.ratio, focused: focusedIndex, peek: config.accordionPadding)
                    frames = Dictionary(uniqueKeysWithValues: zip(tiled.map(\.id), list))
                }
                for window in tiled {
                    guard let frame = frames[window.id] else { continue }
                    window.hiddenFrame = nil
                    let current = bounds[window.id]
                    if current?.isClose(to: frame, tolerance: Self.frameTolerance) ?? false {
                        window.crossDisplayTarget = nil
                    } else {
                        setFrame(window, frame, from: current, screens: screens)
                    }
                }
            }
            scheduleSave()
        }
    }

    /// Whether `frame` is a native full-screen window's: it covers a whole display, menu bar
    /// included. Not told on a display whose tiling area is all of it (no menu bar, no Dock,
    /// no padding): a lone tile there is as large, and would be left out of the layout.
    static func isFullScreen(_ frame: CGRect, displays: [(frame: CGRect, area: CGRect)]) -> Bool {
        displays.contains {
            frame.isClose(to: $0.frame, tolerance: looseTolerance) && !$0.area.isClose(to: $0.frame, tolerance: looseTolerance)
        }
    }

    /// The display's visible frame (no menu bar, no Dock) less the padding: every layout
    /// works inside it, never in absolute screen coordinates of its own.
    func area(of screen: ScreenInfo) -> CGRect {
        let area = screen.visible.insetBy(dx: config.padding, dy: config.padding)
        return area.width > 0 && area.height > 0 ? area : screen.visible
    }

    /// The dialogs of a window: they share its workspace and come and go with it.
    func dialogWindows(of window: ManagedWindow) -> [ManagedWindow] {
        windows.values.filter { $0.parent == window.id }
    }

    /// Puts a window in a workspace, with its dialogs (they share its workspace); returns them all.
    @discardableResult
    func setWorkspace(_ workspace: Int, of window: ManagedWindow) -> [ManagedWindow] {
        let moving = [window] + dialogWindows(of: window)
        moving.forEach { $0.workspace = workspace }
        return moving
    }

    /// `current`, when known, lets a move within a display skip the writes it does not need.
    func setFrame(_ window: ManagedWindow, _ frame: CGRect, from current: CGRect? = nil, screens: [ScreenInfo]? = nil) {
        window.movedByUs = Date()
        let sameDisplay = current.map { Self.sameDisplay($0, frame, screens ?? currentScreens()) } ?? false
        let steps = Self.frameSteps(from: current, to: frame, sameDisplay: sameDisplay)
        guard !steps.isEmpty else { return }
        let app = apps[window.pid]?.element
        let axState = apps[window.pid]?.axState
        let element = window.element
        let name = window.appLabel
        axQueues.perform(window.pid) { [weak self, weak window] in
            // AXEnhancedUserInterface (set by VoiceOver-aware tools) makes some apps
            // animate every AX resize; switch it off while we move the window. Read once per
            // app, and again after a move that failed.
            let enhanced = axState?.enhancedUI ?? app.flatMap { AX.bool($0, "AXEnhancedUserInterface") } ?? false
            axState?.enhancedUI = enhanced
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
            if !sameDisplay, failure == .success, let actual = AX.frame(element), !actual.isClose(to: frame, tolerance: Self.frameTolerance) {
                AX.setPosition(element, frame.origin)
                AX.setSize(element, frame.size)
            }
            if failure != .success {
                axState?.enhancedUI = nil
                DispatchQueue.main.async { self?.note("moving a window of \(name) failed: AX error \(failure.rawValue)") }
            }
            if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", true) }
            // Counted from the write itself: a busy app may get to it much later than it was asked.
            DispatchQueue.main.async { window?.movedByUs = Date() }
        }
        // Others resize themselves a moment later, for the scale of the new display; that
        // resize comes too soon to count as the user's, so look again once it is done.
        // Once per tile: a window that never gets there (its app hung, a minimum size keeping
        // its center on the other display) would otherwise be retiled for ever.
        if current != nil, !sameDisplay, takesTile(window), Self.looksAgain(at: frame, after: window.crossDisplayTarget) {
            window.crossDisplayTarget = frame
            DispatchQueue.main.asyncAfter(delays: Delay.crossDisplaySettle) { [weak self] in self?.scheduleRetile() }
        }
    }

    /// Whether a window sent across displays to `target` is looked at again a moment later:
    /// not when it was already, for that same tile (`last`), and has not got there since.
    static func looksAgain(at target: CGRect, after last: CGRect?) -> Bool {
        !(last?.isClose(to: target, tolerance: frameTolerance) ?? false)
    }

    enum FrameStep { case size, position }

    /// The AX writes that take a window from `current` to `target`. Across displays (or from
    /// an unknown frame): size → position → size, the first resize lets the window fit on
    /// the destination display, the second fixes apps that clamp to the old screen. Within a
    /// display only what changed, shrinking before moving so the window never sticks out.
    static func frameSteps(from current: CGRect?, to target: CGRect, sameDisplay: Bool) -> [FrameStep] {
        guard let current, sameDisplay else { return [.size, .position, .size] }
        let sizeChanges = !current.size.isClose(to: target.size, tolerance: Self.frameTolerance)
        let originChanges = !current.origin.isClose(to: target.origin, tolerance: Self.frameTolerance)
        switch (sizeChanges, originChanges) {
        case (false, false): return []
        case (true, false): return [.size]
        case (false, true): return [.position]
        case (true, true):
            let grows = target.width > current.width + frameTolerance || target.height > current.height + frameTolerance
            return grows ? [.position, .size] : [.size, .position]
        }
    }

    private static func sameDisplay(_ a: CGRect, _ b: CGRect, _ screens: [ScreenInfo]) -> Bool {
        !screens.isEmpty && displayIndex(of: a, screens) == displayIndex(of: b, screens)
    }

    /// The display a frame is on: the one holding its center, else the nearest. A parked
    /// window's center is off every display: its display is the one its sliver shows on.
    static func displayIndex(of frame: CGRect, _ screens: [ScreenInfo]) -> Int {
        if isParked(frame, on: screens) {
            let overlaps = screens.indices.map { (index: $0, area: frame.intersection(screens[$0].frame).area) }
            if let best = overlaps.max(by: { $0.area < $1.area }), best.area > 0 { return best.index }
        }
        return screens.index(for: frame)
    }

    /// Visible, normal-layer windows on the current Space with their frames.
    private func windowBounds() -> [CGWindowID: CGRect] {
        Dictionary(WindowList.onScreen().map { ($0.id, $0.bounds) }, uniquingKeysWith: { first, _ in first })
    }

}
