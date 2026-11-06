import AppKit
import ApplicationServices

struct ScreenState {
    var layout: LayoutKind
    var ratio: CGFloat
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
    var onWorkspaceChange: (((names: [String], focused: Int)?) -> Void)?
    /// Called when tiling is turned on or off by the toggle-tiling action.
    var onEnabledChange: ((Bool) -> Void)?
    /// Until then apps opened with a rule do not take you to their workspace: they are the
    /// apps macOS reopens at login, not ones you open. Set when HyperSpace starts at login.
    var revealAfter = Date.distantPast

    var running = false
    var apps: [pid_t: AppWatcher] = [:]
    var windows: [CGWindowID: ManagedWindow] = [:]
    /// The tracked windows of each app, to find the one an AX notification is about.
    private var windowIDs: [pid_t: [CGWindowID]] = [:]
    /// Tiling order; the first window of each screen is the master.
    var order: [CGWindowID] = []
    /// Layout and ratio per display, by display UUID (they survive unplugging it).
    var screenStates: [String: ScreenState] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var retileScheduled = false
    var drag: DragSession?
    /// Dragging writes to the app on its AX queue, one write at a time with only the latest
    /// point waiting; `dragGeneration` tells the writes of an old drag from the current one.
    var dragWriteInFlight = false
    var dragPendingPoint: CGPoint?
    var dragGeneration = 0
    private lazy var refcon = Unmanaged.passUnretained(self).toOpaque()

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
    /// Last value sent to `onWorkspaceChange`, so the menu bar is redrawn only on change.
    var lastNotice: (names: [String], focused: Int)??
    /// Workspaces apps were opened from, for the windows they show while loading.
    private var launches = LaunchTracker()
    private var focusUpdateScheduled = false
    private var snapBackScheduled = false
    /// Running apps are being picked up at start: retile once they all are.
    private var adopting = false
    let writer = AXWriter()
    /// The workspaces saved last time, while the windows found at start are matched to them.
    var restorer: WorkspaceRestorer?
    var restoredState: WorkspaceState?
    var restoredIndex: [CGWindowID: Int] = [:]
    var saveScheduled = false
    /// The last state written, without titles, so an unchanged state is not written again.
    var lastSavedShape: WorkspaceState?
    let saveQueue = DispatchQueue(label: "HyperSpace.state", qos: .utility)
    /// The last problems talking to apps, for the debug report.
    var issues: [String] = []
    /// Apps opened for the scratchpad: their next window goes there (until the date).
    var pendingScratchpad: [String: Date] = [:]
    /// The size a scratchpad window took instead of the one asked for `target`.
    var scratchpadFitted: (target: CGRect, size: CGSize)?
    /// Window lookups still running on the apps' AX queues, and what waits for them.
    private var pendingDiscoveries = 0
    private var afterDiscoveries: [() -> Void] = []

    /// The tracked windows in tiling order.
    var orderedWindows: [ManagedWindow] { order.compactMap { windows[$0] } }

    /// The smallest size resizing by hand (a shortcut, a drag) takes a window to.
    static let minimumWindowSize = CGSize(width: 160, height: 100)

    /// At least one workspace per display, even when fewer are configured.
    var workspaceCount: Int { max(1, config.workspaces.count, NSScreen.screens.count) }

    func name(of workspace: Int) -> String {
        workspace < config.workspaces.count ? config.workspaces[workspace] : "\(workspace + 1)"
    }

    /// Whether the rules make a window float: a dialog, or an app or title rule. The title (an
    /// AX read) is only asked for when a rule looks at titles.
    private func shouldFloat(_ window: ManagedWindow, title: () -> String?) -> Bool {
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
                window.isFloating = shouldFloat(window) { AX.string(window.element, kAXTitleAttribute) }
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
        writer.flush(timeout: 1.5)
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
        for delay in [2.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.rescan() }
        }
    }

    private func displaysChanged() {
        // The focused window of the removed display moving must not switch workspaces.
        ignoreFocusChanges()
        syncDisplays()
        scheduleRetile()
        // macOS relocates the windows of the removed display a moment after the notification.
        for delay in [0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleRetile() }
        }
        notifyWorkspace()
    }

    /// Some apps create their first window before AX describes it (no subrole yet) or without
    /// announcing it: look again a few times, so an app with a rule goes to its workspace
    /// right away instead of when it is focused.
    private func lookAgainAfterLaunch(_ pid: pid_t) {
        for delay in [0.5, 1.5, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let watcher = apps[pid] else { return }
                discover(watcher)
            }
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
        pendingDiscoveries = 0
        afterDiscoveries.removeAll()
    }

    /// After a crash windows can be left parked off-screen: bring them back.
    private func rescueStrandedWindows() {
        let screens = currentScreens()
        guard let main = screens.first else { return }
        for (id, frame) in currentBounds() {
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
            log.debug("watch \(watcher.bundleID ?? "?", privacy: .public)")
            discover(watcher)
        } else if attempt < 20 {
            if attempt == 0 || attempt == 19 { note("cannot watch \(app.bundleIdentifier ?? "?") yet (attempt \(attempt + 1))") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.addApp(app, attempt: attempt + 1)
            }
        }
    }

    private func removeApp(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.invalidate()
        writer.forget(pid)
        for id in windowIDs[pid] ?? [] { untrack(id) }
        scheduleRetile()
    }

    /// Looks for windows not tracked yet. The app is asked on its own AX queue (a slow app
    /// does not hold up the others or the shortcuts); new windows are tracked on the main
    /// thread and retiled.
    private func discover(_ watcher: AppWatcher, then done: (() -> Void)? = nil) {
        let pid = watcher.pid
        let app = watcher.element
        pendingDiscoveries += 1
        writer.read(pid, {
            let main = AX.element(app, kAXMainWindowAttribute).flatMap(AX.windowID)
            return AX.elements(app, kAXWindowsAttribute).map { AX.probe($0, pid: pid, main: .some(main)) }
        }, then: { [weak self] probes in
            guard let self else { return }
            enterScope()
            defer { leaveScope() }
            var found = false
            if running, apps[pid] === watcher {
                for probe in probes where track(probe, in: watcher) != nil { found = true }
            }
            if found { scheduleRetile() }
            done?()
            discoveryFinished()
        })
    }

    private func discoveryFinished() {
        pendingDiscoveries = max(0, pendingDiscoveries - 1)
        guard pendingDiscoveries == 0, !afterDiscoveries.isEmpty else { return }
        let waiting = afterDiscoveries
        afterDiscoveries.removeAll()
        waiting.forEach { $0() }
    }

    /// Runs `block` once the window lookups in flight are done (at most 3 s later: a hung app
    /// must not keep the others from tiling).
    private func whenDiscovered(_ block: @escaping () -> Void) {
        guard pendingDiscoveries > 0 else { return block() }
        var ran = false
        let once = { if !ran { ran = true; block() } }
        afterDiscoveries.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: once)
    }

    /// Starts managing a window; nil when it is already known or not a window to manage.
    @discardableResult
    private func track(_ probe: AX.WindowProbe, in watcher: AppWatcher) -> ManagedWindow? {
        let element = probe.element
        let appID = watcher.bundleID ?? "?"
        let role = probe.role ?? "-"
        guard let id = probe.id else {
            // The Finder desktop (a scroll area) is listed among its windows: not worth a line.
            guard probe.role != kAXScrollAreaRole, probe.kind != .pending else { return nil }
            note("no window id for a window of \(appID) (role \(role))")
            return nil
        }
        guard windows[id] == nil else { return nil }
        guard probe.kind == .standard || probe.kind == .dialog else {
            log.debug("skip window of \(appID, privacy: .public): role \(role, privacy: .public) subrole \(probe.subrole ?? "-", privacy: .public)")
            return nil
        }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isDialog = probe.kind == .dialog || probe.dialogLike
        window.isFloating = shouldFloat(window) { probe.title }
        // A dialog belongs to the window it was opened from: the app's main window, else the
        // app's window focused last, else any of its windows.
        let parent = window.isDialog ? dialogParent(of: watcher.pid, main: probe.mainWindow, excluding: id) : nil
        window.parent = parent?.id
        // Right after start, the window this one was before HyperSpace (or the Mac) restarted.
        var restored: WorkspaceState.Window?
        if parent == nil, let app = watcher.bundleID, let index = restorer?.claim(app: app, title: probe.title),
           let saved = restorer?.window(index) {
            restored = saved
            restoredIndex[id] = index
            if let floating = saved.floating {
                window.isFloating = floating
                window.userOverride = true
            }
            window.scratchpad = saved.scratchpad ?? false
        }
        // The app was opened by its scratchpad shortcut: this window is the scratchpad one.
        if parent == nil, let app = watcher.bundleID, let until = pendingScratchpad[app] {
            pendingScratchpad[app] = nil
            if Date() < until {
                window.scratchpad = true
                DispatchQueue.main.async { [weak self] in self?.showScratchpad(window) }
            }
        }
        // Opened while you work in a scratchpad window of its app (⌘N, or ⌘T in a terminal):
        // it joins the scratchpad instead of the tiling.
        if parent == nil, !window.scratchpad, restored == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == watcher.pid,
           let current = windows.values.filter({ $0.pid == watcher.pid }).max(by: { $0.focusedAt < $1.focusedAt }),
           current.scratchpad, current.scratchpadShown {
            log.debug("window \(id) opened from scratchpad window \(current.id): joins the scratchpad")
            window.scratchpad = true
            window.focusedAt = Date()
            DispatchQueue.main.async { [weak self] in self?.showScratchpad(window) }
        }
        // A window joins its parent's workspace (a dialog), its app's assigned workspace, the
        // one it had before a restart, the one the app was opened from (you may have moved on
        // while it loaded), or the one shown where it appears.
        let launch = launches.workspace(for: watcher.pid)
        let assigned = watcher.bundleID.flatMap { config.assignments[$0] }
        if let parent {
            window.workspace = parent.workspace
        } else {
            window.workspace = Self.newWindowWorkspace(assigned: assigned, restored: restored?.workspace, launch: launch,
                                                       workspaces: workspaceCount) { [self] in
                if let frame = probe.frame, let screen = currentScreens().screen(for: frame) {
                    return displayed[screen.id]
                }
                return focusedWorkspace
            }
        }
        // An app with a rule you just opened takes you to its workspace, however its first
        // window was found (an app slow to answer is picked up by a later look).
        if parent == nil, let assigned, assigned < workspaceCount, launch != nil, restored == nil, !window.scratchpad { reveal(window) }
        windows[id] = window
        scope?.bounds = nil // a new window: what a command read before may lack it
        windowIDs[window.pid, default: []].append(id)
        order.append(id)
        watcher.watch(element)
        log.debug("track \(watcher.bundleID ?? "?", privacy: .public) window \(id) workspace \(window.workspace) floating \(window.isFloating)\(parent.map { " dialog of \($0.id)" } ?? "")")
        return window
    }

    /// The window a new dialog of `pid` belongs to.
    private func dialogParent(of pid: pid_t, main: CGWindowID?, excluding id: CGWindowID) -> ManagedWindow? {
        let mine = orderedWindows.filter { $0.pid == pid && $0.id != id && $0.parent == nil }
        if let main, let window = mine.first(where: { $0.id == main }) { return window }
        if let window = mine.first(where: { lastFocused[$0.workspace] == $0.id && display(showing: $0.workspace) != nil }) { return window }
        return mine.first { display(showing: $0.workspace) != nil } ?? mine.first
    }

    /// The workspace of a new window: its app's rule, the one it had before a restart, the one
    /// its app was opened from, else the one shown where it appears (`whereItAppears`, only
    /// asked then). Out-of-range choices are skipped.
    static func newWindowWorkspace(assigned: Int?, restored: Int?, launch: Int?, workspaces: Int,
                                   whereItAppears: () -> Int?) -> Int {
        for choice in [assigned, restored, launch] {
            if let choice, choice < workspaces { return choice }
        }
        return whereItAppears() ?? 0
    }

    /// Shows the workspace of a window just tracked, once tracking is done.
    private func reveal(_ window: ManagedWindow) {
        // Apps opened together with the Mac at login must not flip through their workspaces.
        guard Date() > revealAfter else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, windows[window.id] === window, display(showing: window.workspace) == nil else { return }
            log.debug("reveal workspace \(window.workspace) for opened app \(window.bundleID ?? "?", privacy: .public)")
            lastFocused[window.workspace] = window.id
            switchWorkspace(window.workspace)
            // The window may reach the screen a moment later: focus it then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, windows[window.id] === window, display(showing: window.workspace) != nil,
                      focused()?.id != window.id, currentBounds()[window.id] != nil else { return }
                focus(window)
            }
        }
    }

    private func untrack(_ id: CGWindowID) {
        if let pid = windows[id]?.pid, var ids = windowIDs[pid] {
            ids.removeAll { $0 == id }
            windowIDs[pid] = ids.isEmpty ? nil : ids
        }
        windows[id] = nil
        order.removeAll { $0 == id }
        lastFocused = lastFocused.filter { $0.value != id }
    }

    /// Space switch: pick up windows AX could not see before and drop dead ones.
    private func rescan() {
        let alive = Set(
            (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        )
        for id in windows.keys where !alive.contains(id) { untrack(id) }
        for watcher in apps.values { discover(watcher) }
        whenDiscovered { [weak self] in
            self?.applyRestoredLayout()
            self?.scheduleRetile()
        }
    }

    func handle(_ notification: String, element: AXUIElement) {
        guard running else { return }
        let pid = AX.pid(element)
        switch notification {
        case kAXWindowCreatedNotification:
            windowCreated(element, pid: pid)
        case kAXUIElementDestroyedNotification:
            guard let id = managed(element, pid: pid)?.id else { return }
            untrack(id)
            scheduleRetile()
        case kAXMovedNotification, kAXResizedNotification:
            // Moved or resized by hand: back to its tile once the mouse is released. Our own
            // moves land on the target frame, so the retile has nothing to do for them.
            guard let window = managed(element, pid: pid) else { return }
            if window.hiddenFrame != nil {
                // A parked window moved by macOS (a display went away): parked again.
                if Date().timeIntervalSince(window.movedByUs) > 0.5 { scheduleRetile() }
                return
            }
            guard !window.isFloating, !window.scratchpad,
                  // A window that cannot take its tile (a minimum size) must not loop.
                  Date().timeIntervalSince(window.movedByUs) > 0.5 else { return }
            scheduleSnapBack()
        case kAXFocusedWindowChangedNotification:
            scheduleFocusUpdate()
        case kAXTitleChangedNotification:
            // Many windows set their title a moment after opening: title rules apply then.
            guard !config.floatingWindows.isEmpty,
                  let window = managed(element, pid: pid),
                  !window.userOverride else { return }
            let floats = shouldFloat(window) { AX.string(element, kAXTitleAttribute) }
            guard floats != window.isFloating else { return }
            window.isFloating = floats
            scheduleRetile()
        default:
            scheduleRetile()
        }
    }

    /// A new window: described on its app's AX queue, then tracked. A window AX does not
    /// describe yet (no subrole) is looked at again a few times.
    private func windowCreated(_ element: AXUIElement, pid: pid_t, attempt: Int = 0) {
        writer.read(pid, { AX.probe(element, pid: pid) }, then: { [weak self] probe in
            guard let self, running, let watcher = apps[pid] else { return }
            enterScope()
            defer { leaveScope() }
            if probe.kind == .pending, attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(1 << attempt)) { [weak self] in
                    self?.windowCreated(element, pid: pid, attempt: attempt + 1)
                }
                return
            }
            guard let window = track(probe, in: watcher) else { return }
            windowTracked(window, watcher: watcher)
        })
    }

    private func windowTracked(_ window: ManagedWindow, watcher: AppWatcher) {
        enterScope()
        defer { leaveScope() }
        let pid = watcher.pid
        // A scratchpad window is shown where you are, whatever its workspace.
        if window.scratchpad { return }
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
    }

    /// The tracked window of an AX element, compared locally (asking the app for the
    /// window id would be a round trip, and a destroyed element has none left).
    private func managed(_ element: AXUIElement, pid: pid_t) -> ManagedWindow? {
        for id in windowIDs[pid] ?? [] {
            if let window = windows[id], CFEqual(window.element, element) { return window }
        }
        return nil
    }

    // MARK: - Layout

    /// Coalesces bursts of events (an app opening five windows) into one retile.
    func scheduleRetile() {
        guard running, !adopting, !retileScheduled else { return }
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
            enterScope()
            defer { leaveScope() }
            let window = focused()
            if let window, window.pid != lastFrontPID {
                // Its app came to the front (⌘Tab, a click, the Dock): its dialogs come along.
                let dialogs = dialogs(of: window)
                if !dialogs.isEmpty { writer.perform(window.pid) { dialogs.forEach(AX.raise) } }
            }
            lastFrontPID = window?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
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

    func retile() {
        guard running, config.enabled, drag == nil else { return }
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
                    if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame, screens: screens) }
                    else { keepHidden(window, bounds: bounds, screens: screens) }
                } else if let frame = bounds[owner.id], let screen = screens.screen(for: frame) {
                    restore(window, on: screen, screens)
                }
                continue
            }
            if window.scratchpad {
                // Out of the workspaces: parked unless shown.
                if !window.scratchpadShown {
                    if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame, screens: screens) }
                    else { keepHidden(window, bounds: bounds, screens: screens) }
                }
                continue
            }
            if !shown.contains(window.workspace) {
                if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame, screens: screens) }
                else { keepHidden(window, bounds: bounds, screens: screens) }
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

    /// Focus changes in the next moment come from us (hiding windows makes apps refocus),
    /// not from the user, and must not switch workspaces.
    /// Counts focus requests, so a retry of an old one gives up.
    var focusRequest = 0

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
        writer.perform(window.pid) {
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
            guard self?.focusRequest == request,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
            guard let self else { return }
            note("focus did not take for \(window.bundleID ?? "?") window \(window.id), retrying")
            ignoreFocusChanges()
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
            writer.perform(window.pid) { AX.focus(window.element, pid: window.pid) }
        }
    }

    /// The dialogs of a window that are on screen: they come to the front with it.
    private func dialogs(of window: ManagedWindow) -> [AXUIElement] {
        windows.values.filter { $0.parent == window.id && $0.hiddenFrame == nil && !$0.scratchpad }.map(\.element)
    }

    /// Moves the pointer to `point` when it is on another display than `screen`.
    func bringPointer(to point: CGPoint, on screen: ScreenInfo) {
        guard config.mouseFollowsFocus, !screen.frame.contains(AX.pointer) else { return }
        AX.warpPointer(to: point)
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
        writer.perform(window.pid) { [weak self] in
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
            if !sameDisplay, failure == .success, let size = AX.size(element), let origin = AX.position(element),
               abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1
                || abs(origin.x - frame.minX) > 1 || abs(origin.y - frame.minY) > 1 {
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
            for delay in [0.3, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleRetile() }
            }
        }
    }

    enum FrameStep { case size, position }

    /// The AX writes that take a window from `current` to `target`. Across displays (or from
    /// an unknown frame): size → position → size, the first resize lets the window fit on
    /// the destination display, the second fixes apps that clamp to the old screen. Within a
    /// display only what changed, shrinking before moving so the window never sticks out.
    static func frameSteps(from current: CGRect?, to target: CGRect, sameDisplay: Bool) -> [FrameStep] {
        guard let current, sameDisplay else { return [.size, .position, .size] }
        let sizeChanges = abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1
        let originChanges = abs(current.minX - target.minX) > 1 || abs(current.minY - target.minY) > 1
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
