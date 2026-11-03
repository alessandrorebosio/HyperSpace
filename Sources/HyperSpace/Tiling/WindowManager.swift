import AppKit
import ApplicationServices

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    var isFloating = false
    /// A dialog (or dialog-like window: no zoom, no full screen): always floats unless toggled by hand.
    var isDialog = false
    /// The window a dialog belongs to: it shares its workspace and comes to the front with it.
    var parent: CGWindowID?
    /// Set once the user toggles floating by hand; config reloads then leave it alone.
    var userOverride = false
    var workspace = 0
    /// Where the window was before its workspace was hidden.
    var hiddenFrame: CGRect?
    /// Share of the split it is in (stack or columns), changed by resizing.
    var weight: CGFloat = 1
    /// When we last moved it: the moves this causes are ours, not the user's.
    var movedByUs = Date.distantPast
    /// Out of the tiling and the workspaces: shown centered above the others on demand.
    var scratchpad = false
    /// A scratchpad window on screen (it stays there across workspace switches).
    var scratchpadShown = false

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

    private var running = false
    private var apps: [pid_t: AppWatcher] = [:]
    private var windows: [CGWindowID: ManagedWindow] = [:]
    /// The tracked windows of each app, to find the one an AX notification is about.
    private var windowIDs: [pid_t: [CGWindowID]] = [:]
    /// Tiling order; the first window of each screen is the master.
    private var order: [CGWindowID] = []
    /// Layout and ratio per display, by display UUID (they survive unplugging it).
    private var screenStates: [String: ScreenState] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?
    private var retileScheduled = false
    private var drag: DragSession?
    /// Dragging writes to the app on its AX queue, one write at a time with only the latest
    /// point waiting; `dragGeneration` tells the writes of an old drag from the current one.
    private var dragWriteInFlight = false
    private var dragPendingPoint: CGPoint?
    private var dragGeneration = 0
    private lazy var refcon = Unmanaged.passUnretained(self).toOpaque()

    /// The workspace each display shows.
    private var displayed: [CGDirectDisplayID: Int] = [:]
    /// Workspaces moved to another display than their default one, by display UUID (a
    /// monitor plugged in again may get another id).
    private var homeOverride: [Int: String] = [:]
    /// What each display that went away (unplugged, asleep) showed, by UUID: shown again
    /// when it comes back.
    private var departed: [String: Int] = [:]
    private let displayMonitor = DisplayMonitor()
    /// An invisible window of HyperSpace's own that takes the key focus on a display with
    /// nothing to focus, so macOS treats that display as the active one.
    private lazy var focusAnchor = FocusAnchor()
    /// The app focused last, to bring dialogs forward only when their app comes to the front.
    private var lastFrontPID: pid_t?
    /// The workspace each display showed before the current one.
    private var shownBefore: [CGDirectDisplayID: Int] = [:]
    /// Column arrangement of each workspace (columns layout), accordions included.
    private var columns: [Int: ColumnLayout] = [:]
    /// Workspaces stacked as an accordion on top of a tall, wide or monocle layout (in columns
    /// the accordion is a column of `ColumnLayout`).
    private var accordionWorkspaces: Set<Int> = []
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
    /// The display of an empty workspace holding the focus (the focus anchor is there): the
    /// display you work on, even while the window left behind still looks focused to macOS.
    private var heldDisplay: CGDirectDisplayID?
    /// Last value sent to `onWorkspaceChange`, so the menu bar is redrawn only on change.
    private var lastNotice: (names: [String], focused: Int)??
    /// Workspaces apps were opened from, for the windows they show while loading.
    private var launches = LaunchTracker()
    private var focusUpdateScheduled = false
    private var snapBackScheduled = false
    /// Running apps are being picked up at start: retile once they all are.
    private var adopting = false
    private let writer = AXWriter()
    /// The workspaces saved last time, while the windows found at start are matched to them.
    private var restorer: WorkspaceRestorer?
    private var restoredState: WorkspaceState?
    private var restoredIndex: [CGWindowID: Int] = [:]
    private var saveScheduled = false
    /// The last state written, without titles, so an unchanged state is not written again.
    private var lastSavedShape: WorkspaceState?
    private let saveQueue = DispatchQueue(label: "HyperSpace.state", qos: .utility)
    /// The last problems talking to apps, for the debug report.
    private var issues: [String] = []
    /// Apps opened for the scratchpad: their next window goes there (until the date).
    private var pendingScratchpad: [String: Date] = [:]
    /// The size a scratchpad window took instead of the one asked for `target`.
    private var scratchpadFitted: (target: CGRect, size: CGSize)?
    /// Window lookups still running on the apps' AX queues, and what waits for them.
    private var pendingDiscoveries = 0
    private var afterDiscoveries: [() -> Void] = []

    /// The tracked windows in tiling order.
    private var orderedWindows: [ManagedWindow] { order.compactMap { windows[$0] } }

    /// The smallest size resizing by hand (a shortcut, a drag) takes a window to.
    static let minimumWindowSize = CGSize(width: 160, height: 100)

    /// At least one workspace per display, even when fewer are configured.
    private var workspaceCount: Int { max(1, config.workspaces.count, NSScreen.screens.count) }

    private func name(of workspace: Int) -> String {
        workspace < config.workspaces.count ? config.workspaces[workspace] : "\(workspace + 1)"
    }

    // MARK: - What a command reads from the system, once

    /// The displays, the on-screen windows and the focused window cost a window-server query,
    /// several `NSScreen` reads and a synchronous AX round trip. A command (a shortcut, a
    /// notification) reads each at most once: between `enterScope` and `leaveScope` the first
    /// read is kept and every function the command calls shares it. Scopes nest, so a command
    /// calling another one stays in its own. Outside a scope every read is fresh.
    private struct Scope {
        var screens: [ScreenInfo]?
        var bounds: [CGWindowID: CGRect]?
        var focusedRead = false
        var focused: ManagedWindow?
    }

    private var scope: Scope?
    private var scopeDepth = 0

    private func enterScope() {
        scopeDepth += 1
        if scopeDepth == 1 { scope = Scope() }
    }

    private func leaveScope() {
        scopeDepth -= 1
        if scopeDepth == 0 { scope = nil }
    }

    private func currentScreens() -> [ScreenInfo] {
        if let screens = scope?.screens { return screens }
        let screens = ScreenInfo.current()
        scope?.screens = screens
        return screens
    }

    private func currentBounds() -> [CGWindowID: CGRect] {
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
            let byTitle = !config.floatingWindows.isEmpty
            for window in windows.values where !window.userOverride {
                window.isFloating = window.isDialog
                    || config.floats(app: window.bundleID, title: byTitle ? AX.string(window.element, kAXTitleAttribute) : nil)
            }
        }
        // Fewer workspaces than before: their windows join the first one.
        let count = workspaceCount
        displayed = displayed.filter { $0.value < count }
        homeOverride = homeOverride.filter { $0.key < count }
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
        syncDisplays()
        scheduleRetile()
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
              let workspace = focusedScreen().flatMap({ displayed[$0.id] }) else { return }
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
            AX.elements(app, kAXWindowsAttribute).map { AX.probe($0, pid: pid) }
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
            let message = "no window id for a window of \(appID) (role \(role))"
            log.debug("\(message, privacy: .public)")
            note(message)
            return nil
        }
        guard windows[id] == nil else { return nil }
        guard probe.kind == .standard || probe.kind == .dialog else {
            log.debug("skip window of \(appID, privacy: .public): role \(role, privacy: .public) subrole \(probe.subrole ?? "-", privacy: .public)")
            return nil
        }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isDialog = probe.kind == .dialog || probe.dialogLike
        window.isFloating = window.isDialog
            || config.floats(app: watcher.bundleID, title: config.floatingWindows.isEmpty ? nil : probe.title)
        // A dialog belongs to the window it was opened from: the app's main window, else the
        // app's window focused last, else any of its windows.
        let parent = window.isDialog ? dialogParent(of: watcher.pid, main: probe.mainWindow, excluding: id) : nil
        window.parent = parent?.id
        // Right after start, the window this one was before HyperSpace (or the Mac) restarted.
        var restored: WorkspaceState.Window?
        if restorer != nil, parent == nil, let app = watcher.bundleID,
           let index = restorer?.claim(app: app, title: probe.title) {
            restored = restorer?.window(index)
            restoredIndex[id] = index
            if let floating = restored?.floating {
                window.isFloating = floating
                window.userOverride = true
            }
            window.scratchpad = restored?.scratchpad ?? false
        }
        // The app was opened by its scratchpad shortcut: this window is the scratchpad one.
        if parent == nil, let app = watcher.bundleID, let until = pendingScratchpad[app] {
            pendingScratchpad[app] = nil
            if Date() < until {
                window.scratchpad = true
                DispatchQueue.main.async { [weak self] in self?.showScratchpad(window) }
            }
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
                if let frame = probe.frame, case let screens = currentScreens(), !screens.isEmpty {
                    return displayed[screens[screens.index(for: frame)].id]
                }
                return focusedScreen().flatMap { displayed[$0.id] }
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

    // MARK: - Scratchpad

    /// Shows or hides an app's scratchpad window, opening the app (or a window of it) first
    /// when needed; with no app, the windows sent to the scratchpad.
    func toggleScratchpad(app name: String?) {
        enterScope()
        defer { leaveScope() }
        guard running else { return }
        let focusedID = focused()?.id
        guard let name else {
            let pad = orderedWindows.filter(\.scratchpad)
            if let shown = pad.first(where: { $0.scratchpadShown && $0.id == focusedID }) {
                hideScratchpad(shown)
            } else if let shown = pad.first(where: \.scratchpadShown) {
                focus(shown)
            } else if let hidden = pad.first {
                showScratchpad(hidden)
            }
            return
        }
        guard let (bundleID, mine) = appWindows(of: name) else { return }
        if let window = mine.first(where: \.scratchpad) {
            if window.scratchpadShown, window.id == focusedID { hideScratchpad(window) } else { showScratchpad(window) }
        } else if let window = mine.first(where: { $0.id == focusedID }) ?? mine.first {
            // Already open in the tiling: it moves to the scratchpad.
            window.scratchpad = true
            showScratchpad(window)
        } else {
            // Not open, or no window: its next window is the scratchpad one.
            pendingScratchpad = pendingScratchpad.filter { $0.value > Date() }
            pendingScratchpad[bundleID] = Date().addingTimeInterval(30)
            AppLauncher.open(name)
        }
    }

    /// The focused window, or with an app that app's window, goes into the scratchpad (shown),
    /// or from it into the tiling of the workspace you are on. An app not open is opened.
    func moveToScratchpad(app name: String?) {
        enterScope()
        defer { leaveScope() }
        guard running else { return }
        guard let name else {
            if let window = focused() { toggleScratchpadTiling(window) }
            return
        }
        guard let (_, mine) = appWindows(of: name) else { return }
        let focusedID = focused()?.id
        if let window = mine.first(where: \.scratchpad) ?? mine.first(where: { $0.id == focusedID }) ?? mine.first {
            toggleScratchpadTiling(window)
        } else {
            AppLauncher.open(name)
        }
    }

    /// The tracked windows, in tiling order, of the app a scratchpad action names (a bundle id
    /// or an app name); nil, with a note for the debug report, when no such app is installed.
    private func appWindows(of name: String) -> (bundleID: String, windows: [ManagedWindow])? {
        guard let bundleID = AppLauncher.bundleID(for: name) else {
            note("scratchpad: app not found: \(name)")
            return nil
        }
        return (bundleID, orderedWindows.filter { $0.bundleID == bundleID })
    }

    private func toggleScratchpadTiling(_ window: ManagedWindow) {
        if window.scratchpad {
            window.scratchpad = false
            window.scratchpadShown = false
            window.hiddenFrame = nil
            window.workspace = focusedScreen().flatMap { displayed[$0.id] } ?? window.workspace
            log.debug("window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) back into workspace \(window.workspace)")
            retile()
            focus(window)
        } else {
            window.scratchpad = true
            showScratchpad(window)
            retile()
        }
    }

    private func showScratchpad(_ window: ManagedWindow) {
        guard windows[window.id] === window, window.scratchpad else { return }
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard let screen = focusedScreen() ?? screens.first else { return }
        ignoreFocusChanges()
        let target = Self.scratchpadFrame(in: screen.visible, size: config.scratchpadSize)
        let frame = scratchpadFitted.flatMap { $0.target == target ? target.centered($0.size, rounded: true) : nil } ?? target
        let current = currentBounds()[window.id]
        log.debug("show scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) on display \(screen.id)")
        window.scratchpadShown = true
        window.hiddenFrame = nil
        setFrame(window, frame, from: current, screens: screens)
        // Apps that size in steps (terminals) or have a minimum size miss the exact size:
        // centered on what they took, and the other scratchpad windows take it too.
        let element = window.element
        let misses = { (size: CGSize) in abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1 }
        writer.perform(window.pid, retryAfter: 0.1) { [weak self] isRetry in
            guard var size = AX.size(element) else { return false }
            // Coming from another display, some apps resize themselves a moment after the
            // move (a different scale): look again 0.1 s later (the app's queue is free
            // meanwhile) and ask once more before taking their size as their best.
            if misses(size) {
                if !isRetry { return true }
                AX.setSize(element, frame.size)
                size = AX.size(element) ?? size
            }
            guard let origin = AX.position(element) else { return false }
            if misses(size) {
                DispatchQueue.main.async { self?.scratchpadFitted = (target, size) }
            }
            let centered = target.centered(size, rounded: true)
            if abs(origin.x - centered.minX) > 1 || abs(origin.y - centered.minY) > 1 {
                AX.setPosition(element, centered.origin)
            }
            return false
        }
        // Where it is going, not the corner it was parked in (another display maybe).
        focus(window, at: frame)
        notifyWorkspace()
    }

    private func hideScratchpad(_ window: ManagedWindow) {
        enterScope()
        defer { leaveScope() }
        ignoreFocusChanges()
        window.scratchpadShown = false
        let screens = currentScreens()
        let frame = currentBounds()[window.id]
        if let frame { hide(window, from: frame, screens: screens) }
        log.debug("hide scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public))")
        // Back to what you were doing, on the display it was shown on: the pointer stays there.
        let here = frame.flatMap { screens.isEmpty ? nil : screens[screens.index(for: $0)].id } ?? activeDisplay
        if let workspace = here.flatMap({ displayed[$0] }) ?? screens.first.flatMap({ displayed[$0.id] }) {
            focusWindow(in: workspace)
        }
    }

    /// Centered in the visible area, `size` being fractions of it.
    static func scratchpadFrame(in visible: CGRect, size: CGSize) -> CGRect {
        let fitted = CGSize(width: (visible.width * size.width).rounded(), height: (visible.height * size.height).rounded())
        return visible.centered(fitted, rounded: true)
    }

    // MARK: - Debug report

    private func note(_ issue: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        issues.append("\(time) \(issue)")
        if issues.count > 30 { issues.removeFirst(issues.count - 30) }
    }

    /// What the window manager knows, to paste when something goes wrong. Reads titles.
    func debugReport() -> String {
        enterScope()
        defer { leaveScope() }
        var lines: [String] = []
        lines.append("Tiling: \(running ? "running" : "stopped"), enabled \(config.enabled), layout \(config.layout.rawValue)")
        let screens = currentScreens()
        let focusedID = focusedScreen()?.id
        for (i, screen) in screens.enumerated() {
            let shown = displayed[screen.id].map { "\(name(of: $0)) (#\($0 + 1))" } ?? "none"
            lines.append("Display \(i + 1): id \(screen.id) \(screen.uuid) \(Self.describe(screen.frame)) visible \(Self.describe(screen.visible)) shows \(shown)\(screen.id == focusedID ? " [focused]" : "")")
        }
        if !homeOverride.isEmpty {
            lines.append("Moved workspaces: " + homeOverride.sorted { $0.key < $1.key }.map { "\(name(of: $0.key)) → display \($0.value)" }.joined(separator: ", "))
        }
        if !DisplayMonitor.absent.isEmpty {
            lines.append("Displays left out (asleep or on another input): " + DisplayMonitor.absent.sorted().map(String.init).joined(separator: ", "))
        }
        let bounds = currentBounds()
        for workspace in 0..<workspaceCount {
            let members = orderedWindows.filter { $0.workspace == workspace }
            guard !members.isEmpty else { continue }
            lines.append("Workspace \(name(of: workspace)) (#\(workspace + 1)):")
            for window in members {
                let title = (AX.string(window.element, kAXTitleAttribute) ?? "").prefix(40)
                var flags: [String] = []
                if window.isFloating { flags.append(window.isDialog ? "floating (dialog)" : "floating") }
                if window.scratchpad { flags.append(window.scratchpadShown ? "scratchpad shown" : "scratchpad") }
                if window.hiddenFrame != nil { flags.append("parked") }
                if bounds[window.id] == nil { flags.append("off screen") }
                lines.append("  \(window.bundleID ?? "?") #\(window.id) “\(title)” \(bounds[window.id].map(Self.describe) ?? "-") \(flags.joined(separator: " "))")
            }
        }
        lines.append("Watched apps: " + apps.values.map { $0.bundleID ?? "\($0.pid)" }.sorted().joined(separator: ", "))
        lines.append("Recent issues:" + (issues.isEmpty ? " none" : ""))
        lines += issues.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }

    // MARK: - Saved state

    /// Brings back which workspace each display showed and where workspaces were moved;
    /// windows are matched as they are found, for a minute.
    private func loadSavedState() {
        guard let state = WorkspaceState.load() else { return }
        let screens = currentScreens()
        let ids = Set(screens.map(\.id))
        let byUUID = Dictionary(screens.map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        // Displays by UUID (any display the monitor was plugged into); older states by id.
        if let moved = state.moved {
            for (key, uuid) in moved {
                if let workspace = Int(key), workspace < workspaceCount { homeOverride[workspace] = uuid }
            }
        } else {
            for (key, display) in state.homeOverride {
                if let workspace = Int(key), workspace < workspaceCount, ids.contains(display) { homeOverride[workspace] = ScreenInfo.uuid(of: display) }
            }
        }
        if let shown = state.displays {
            for (uuid, workspace) in shown where workspace < workspaceCount {
                if let display = byUUID[uuid] { displayed[display] = workspace } else { departed[uuid] = workspace }
            }
        } else {
            for (key, workspace) in state.displayed {
                if let display = CGDirectDisplayID(key), ids.contains(display), workspace < workspaceCount { displayed[display] = workspace }
            }
        }
        accordionWorkspaces = Set((state.accordionWorkspaces ?? []).filter { $0 < workspaceCount })
        for (uuid, saved) in state.layouts ?? [:] {
            if let kind = LayoutKind(rawValue: saved.layout) { screenStates[uuid] = ScreenState(layout: kind, ratio: CGFloat(saved.ratio)) }
        }
        restoredState = state
        restorer = WorkspaceRestorer(state)
        log.debug("restoring \(state.windows.count) window(s) saved \(state.savedAt, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.restorer = nil
            self?.restoredState = nil
            self?.restoredIndex = [:]
            self?.scheduleSave()
        }
    }

    /// Restored windows take their saved order and columns.
    private func applyRestoredLayout() {
        guard let state = restoredState, !restoredIndex.isEmpty else { return }
        let restoredIDs = restoredIndex.filter { windows[$0.key] != nil }.sorted { $0.value < $1.value }.map(\.key)
        order = restoredIDs + order.filter { restoredIndex[$0] == nil }
        let idByIndex = Dictionary(restoredIndex.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for (key, saved) in state.columns {
            guard let workspace = Int(key) else { continue }
            columns[workspace] = ColumnLayout(columns: saved.map { $0.compactMap { idByIndex[$0] } },
                                              accordions: Set(state.accordions?[key] ?? []))
        }
    }

    /// The state to save, without titles (read later, off the main thread), and the windows
    /// whose titles go with it.
    private func currentState() -> (state: WorkspaceState, elements: [AXUIElement]) {
        let list = orderedWindows.filter { $0.bundleID != nil }
        var index: [CGWindowID: Int] = [:]
        var state = WorkspaceState(savedAt: .distantPast)
        for (i, window) in list.enumerated() {
            index[window.id] = i
            state.windows.append(.init(app: window.bundleID!, title: "", workspace: window.workspace,
                                       floating: window.userOverride ? window.isFloating : nil,
                                       scratchpad: window.scratchpad ? true : nil))
        }
        var accordions: [String: [Int]] = [:]
        for (workspace, layout) in columns {
            let kept = layout.columns.filter { !$0.windows.compactMap { index[$0] }.isEmpty }
            let saved = kept.map { $0.windows.compactMap { index[$0] } }
            if !saved.isEmpty { state.columns[String(workspace)] = saved }
            let stacked = kept.indices.filter { kept[$0].accordion }
            if !stacked.isEmpty { accordions[String(workspace)] = stacked }
        }
        state.accordions = accordions.isEmpty ? nil : accordions
        state.accordionWorkspaces = accordionWorkspaces.isEmpty ? nil : accordionWorkspaces.sorted()
        var shown = departed
        for (display, workspace) in displayed {
            state.displayed[String(display)] = workspace
            shown[ScreenInfo.uuid(of: display)] = workspace
        }
        state.displays = shown
        state.moved = Dictionary(uniqueKeysWithValues: homeOverride.map { (String($0.key), $0.value) })
        state.layouts = screenStates.mapValues { .init(layout: $0.layout.rawValue, ratio: Double($0.ratio)) }
        return (state, list.map(\.element))
    }

    /// Saves a moment after a change, when something really changed. Not while windows are
    /// still being matched to the saved state, which would lose the apps not reopened yet.
    private func scheduleSave() {
        guard running, restorer == nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            guard running, restorer == nil else { return }
            var (state, elements) = currentState()
            guard state != lastSavedShape else { return }
            lastSavedShape = state
            saveQueue.async {
                for i in elements.indices { state.windows[i].title = AX.string(elements[i], kAXTitleAttribute) ?? "" }
                state.savedAt = Date()
                state.save()
            }
        }
    }

    /// Saves at once (on quit), keeping the saved windows not found again yet.
    func saveState() {
        guard running else { return }
        var (state, elements) = currentState()
        for i in elements.indices { state.windows[i].title = AX.string(elements[i], kAXTitleAttribute) ?? "" }
        if let restorer { state.windows += restorer.unclaimed }
        state.savedAt = Date()
        saveQueue.sync {}
        state.save()
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
            guard let window = managed(element, pid: pid),
                  !window.isFloating, !window.scratchpad, window.hiddenFrame == nil,
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
            let floats = window.isDialog || config.floats(app: window.bundleID, title: AX.string(element, kAXTitleAttribute))
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
    private func scheduleRetile() {
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

        for window in windows.values {
            if window.scratchpad {
                // Out of the workspaces: parked unless shown.
                if !window.scratchpadShown, window.hiddenFrame == nil, let frame = bounds[window.id] {
                    hide(window, from: frame, screens: screens)
                }
                continue
            }
            if !shown.contains(window.workspace) {
                if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame, screens: screens) }
            } else if window.isFloating, let screen = screens.first(where: { displayed[$0.id] == window.workspace }) {
                restore(window, on: screen, screens)
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
                if !(bounds[window.id]?.isClose(to: frame) ?? false) { setFrame(window, frame, from: bounds[window.id], screens: screens) }
            }
        }
        scheduleSave()
    }

    /// The display's visible frame (no menu bar, no Dock) less the padding: every layout
    /// works inside it, never in absolute screen coordinates of its own.
    private func area(of screen: ScreenInfo) -> CGRect {
        let area = screen.visible.insetBy(dx: config.padding, dy: config.padding)
        return area.width > 0 && area.height > 0 ? area : screen.visible
    }

    /// Tiled windows of a workspace that are on screen, in tiling order.
    private func tiledWindows(in workspace: Int, bounds: [CGWindowID: CGRect]) -> [ManagedWindow] {
        orderedWindows.filter {
            $0.workspace == workspace && !$0.isFloating && !$0.scratchpad && bounds[$0.id] != nil
        }
    }

    /// Focus changes in the next moment come from us (hiding windows makes apps refocus),
    /// not from the user, and must not switch workspaces.
    /// Counts focus requests, so a retry of an old one gives up.
    private var focusRequest = 0

    private func ignoreFocusChanges() {
        followFocusAfter = Date().addingTimeInterval(0.6)
    }

    /// Focuses a window without the resulting focus change switching workspaces. Crossing
    /// to another display brings the pointer along (if enabled), and as macOS sometimes
    /// ignores a background app raising a window on another display, it checks and retries.
    /// `frame` is where the window is going, when we just moved it (the move is not done yet).
    private func focus(_ window: ManagedWindow, at frame: CGRect? = nil) {
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
        if let frame = frame ?? currentBounds()[window.id], !screens.isEmpty {
            let screen = screens[screens.index(for: frame)]
            activeDisplay = screen.id
            bringPointer(to: frame.center, on: screen)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            // A later focus (another workspace, keys pressed in a row) wins over this retry.
            guard self?.focusRequest == request,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != window.pid else { return }
            log.debug("focus did not take for window \(window.id) (\(window.bundleID ?? "?", privacy: .public)), retrying")
            self?.note("focus did not take for \(window.bundleID ?? "?") window \(window.id)")
            guard let self else { return }
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
    private func bringPointer(to point: CGPoint, on screen: ScreenInfo) {
        guard config.mouseFollowsFocus, !screen.frame.contains(AX.pointer) else { return }
        AX.warpPointer(to: point)
    }

    /// `current`, when known, lets a move within a display skip the writes it does not need.
    private func setFrame(_ window: ManagedWindow, _ frame: CGRect, from current: CGRect? = nil, screens: [ScreenInfo]? = nil) {
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

    private func state(for screen: CGDirectDisplayID?) -> ScreenState {
        screen.flatMap { screenStates[ScreenInfo.uuid(of: $0)] } ?? ScreenState(layout: config.layout, ratio: config.masterRatio)
    }

    private func setState(_ state: ScreenState, for screen: CGDirectDisplayID) {
        screenStates[ScreenInfo.uuid(of: screen)] = state
    }

    private func updateActiveScreen(_ change: (inout ScreenState) -> Void) {
        enterScope()
        defer { leaveScope() }
        guard let id = focusedScreen()?.id else { return }
        var state = state(for: id)
        change(&state)
        setState(state, for: id)
        scheduleRetile()
    }

    // MARK: - Workspaces

    /// The display a workspace lives on: where it was moved, otherwise workspace n on the
    /// n-th display and the rest on the main one (displays in `ScreenInfo.current()` order).
    private func home(of workspace: Int, _ screens: [ScreenInfo]) -> ScreenInfo? {
        let id = Self.homeDisplay(of: workspace, movedTo: movedTo(workspace, screens), displays: screens.map(\.id))
        return screens.first { $0.id == id }
    }

    /// The connected display a workspace was moved to, if any.
    private func movedTo(_ workspace: Int, _ screens: [ScreenInfo]) -> CGDirectDisplayID? {
        homeOverride[workspace].flatMap { uuid in screens.first { $0.uuid == uuid }?.id }
    }

    /// `displays` in `ScreenInfo.current()` order; a move to a display no longer there is ignored.
    static func homeDisplay(of workspace: Int, movedTo: CGDirectDisplayID?, displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if let movedTo, displays.contains(movedTo) { return movedTo }
        return displays.isEmpty ? nil : displays[homeIndex(of: workspace, displays: displays.count)]
    }

    /// Shows a workspace on a display, remembering what it replaces.
    private func showWorkspace(_ workspace: Int?, on display: CGDirectDisplayID) {
        if let current = displayed[display], current != workspace { shownBefore[display] = current }
        displayed[display] = workspace
    }

    static func homeIndex(of workspace: Int, displays: Int) -> Int {
        workspace < displays ? workspace : 0
    }

    /// Every display shows one of its own workspaces (the lowest numbered by default), or
    /// none when no workspace lives there.
    /// A display that went away remembers what it showed (by UUID), and shows it again when
    /// it comes back, so a monitor plugged in again finds its workspace and windows as they were.
    private func syncDisplays() {
        let screens = currentScreens()
        let ids = screens.map(\.id)
        // Looked up while connected: a display gone may have no UUID to ask for any more.
        for screen in screens { _ = screen.uuid }
        for (display, workspace) in displayed where !ids.contains(display) {
            departed[ScreenInfo.uuid(of: display)] = workspace
        }
        let home = { [self] (workspace: Int) in Self.homeDisplay(of: workspace, movedTo: movedTo(workspace, screens), displays: ids) }
        for screen in screens where displayed[screen.id] == nil {
            guard let workspace = departed.removeValue(forKey: screen.uuid), workspace < workspaceCount,
                  home(workspace) == screen.id else { continue }
            log.debug("display \(screen.id) is back: shows workspace \(workspace) again")
            for (display, shown) in displayed where shown == workspace { displayed[display] = nil }
            displayed[screen.id] = workspace
        }
        displayed = Self.syncedDisplays(displayed, displays: ids, workspaces: workspaceCount, home: home)
    }

    static func syncedDisplays(_ displayed: [CGDirectDisplayID: Int], displays: [CGDirectDisplayID], workspaces: Int,
                               home: (Int) -> CGDirectDisplayID?) -> [CGDirectDisplayID: Int] {
        var result = displayed.filter { displays.contains($0.key) }
        for display in displays {
            if let shown = result[display], home(shown) == display { continue }
            let taken = Set(result.values)
            result[display] = (0..<workspaces).first { home($0) == display && !taken.contains($0) }
        }
        return result
    }

    private func display(showing workspace: Int) -> CGDirectDisplayID? {
        displayed.first { $0.value == workspace }?.key
    }

    /// Shows a workspace on its own display and focuses it; the other displays keep theirs.
    func switchWorkspace(_ index: Int) {
        enterScope()
        defer { leaveScope() }
        guard running, (0..<workspaceCount).contains(index) else { return }
        syncDisplays()
        let screens = currentScreens()
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
            showWorkspace(index, on: screen.id)
            retile()
        }
        // The focus moves asynchronously: the menu bar is told what it will be, not what the
        // old window still is (an empty workspace has no focus change to correct it later).
        let target = focusWindow(in: index)
        notifyWorkspace(focused: .some(target))
    }

    func switchToPreviousWorkspace() {
        if let previousWorkspace { switchWorkspace(previousWorkspace) }
    }

    /// Moves only the focused window; the displays keep showing what they show.
    func moveFocusedWindow(toWorkspace index: Int) {
        enterScope()
        defer { leaveScope() }
        guard running, (0..<workspaceCount).contains(index), let window = focused(), window.workspace != index else { return }
        let source = window.workspace
        ignoreFocusChanges()
        // Its dialogs go along.
        let moving = [window] + windows.values.filter { $0.parent == window.id }
        moving.forEach { $0.workspace = index }
        log.debug("move window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) from workspace \(source) to \(index), shown: \(self.display(showing: index) != nil)")
        // A floating window going to a workspace shown on another display keeps its place there.
        carryFloating(moving, screens: currentScreens())
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
        let element = window.element
        writer.perform(window.pid) { AX.setPosition(element, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)) }
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    private func restore(_ window: ManagedWindow, on screen: ScreenInfo, _ screens: [ScreenInfo]) {
        guard let frame = window.hiddenFrame else { return }
        setFrame(window, Self.place(frame, on: screen, screens))
        window.hiddenFrame = nil
    }

    /// `frame` on `screen`: as it is when already there, else moved from the display it is on
    /// keeping its position and size as shares of the visible area.
    static func place(_ frame: CGRect, on screen: ScreenInfo, _ screens: [ScreenInfo]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let from = screens[screens.index(for: frame)]
        return from.id == screen.id ? frame : from.relocate(frame, to: screen)
    }

    /// Floating windows of `workspaces` on screen but on another display than the one showing
    /// their workspace (it was just moved, or the window was): carried over, proportionally.
    private func carryFloating(_ members: [ManagedWindow], screens: [ScreenInfo]) {
        let bounds = currentBounds()
        for window in members where window.isFloating && !window.scratchpad && window.hiddenFrame == nil {
            guard let frame = bounds[window.id], let id = display(showing: window.workspace),
                  let screen = screens.first(where: { $0.id == id }) else { continue }
            let target = Self.place(frame, on: screen, screens)
            if !target.isClose(to: frame) { setFrame(window, target, from: frame, screens: screens) }
        }
    }

    /// Focuses the workspace: its last focused window, or with no windows, its display.
    /// Returns the window it focuses (nil for the display alone).
    @discardableResult
    private func focusWindow(in workspace: Int) -> ManagedWindow? {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        let candidates = orderedWindows.filter {
            $0.workspace == workspace && !$0.scratchpad && bounds[$0.id] != nil
        }
        if let target = candidates.first(where: { $0.id == lastFocused[workspace] }) ?? candidates.first {
            focus(target)
            return target
        } else if let id = display(showing: workspace), case let screens = currentScreens(),
                  let screen = screens.first(where: { $0.id == id }) {
            activeDisplay = id
            // Already holding the focus there (the same workspace asked again, a held key
            // repeating): nothing to do, the pointer is not clicked again.
            if heldDisplay == id, focusAnchor.shown { return nil }
            bringPointer(to: screen.visible.center, on: screen)
            // Nothing to focus there: take the keyboard away from the window you left (on
            // another display it would keep typing there). An invisible window of ours on that
            // display is clicked, which makes HyperSpace active there: macOS then makes it the
            // active display too (menu bar, new windows, Spotlight open there). Also asked
            // through AX, off the main thread (which has to answer), in case the click is not
            // possible (a mouse button held).
            focusRequest += 1
            heldDisplay = id
            focusAnchor.show(on: screen)
            let me = getpid()
            writer.perform(me) { AX.setBool(AXUIElementCreateApplication(me), kAXFrontmostAttribute, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.focusAnchor.takeKey() }
        }
        return nil
    }

    /// The focus leaves the empty workspace it was held on.
    private func releaseHeldFocus() {
        heldDisplay = nil
        focusAnchor.dismiss()
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    private func followFocus(_ window: ManagedWindow?) {
        guard running, let window else { return }
        // A window focused by the user (not the refocusing we cause): the empty display is left.
        if heldDisplay != nil, Date() > followFocusAfter { releaseHeldFocus() }
        if window.scratchpad {
            // ⌘Tab or the Dock to a hidden scratchpad window: show it instead of a workspace.
            if !window.scratchpadShown, Date() > followFocusAfter { showScratchpad(window) }
            return
        }
        if window.hiddenFrame == nil, let id = display(showing: window.workspace) {
            activeDisplay = id
            if lastFocused[window.workspace] != window.id {
                lastFocused[window.workspace] = window.id
                // An accordion brings the focused window to the front, in the middle.
                if !window.isFloating, inAccordion(window, layout: state(for: id).layout) {
                    columns[window.workspace]?.setFront(window.id)
                    scheduleRetile()
                }
            }
        }
        if window.id != movedAway { movedAway = nil }
        guard Date() > followFocusAfter, window.id != movedAway, display(showing: window.workspace) == nil else { return }
        log.debug("follow focus to window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) in workspace \(window.workspace)")
        switchWorkspace(window.workspace)
    }

    /// Tells the menu bar what each display shows; called often (every focus change), so it
    /// only looks up the focused display when there are several, and only reports changes.
    private func notifyWorkspace(focused window: ManagedWindow?? = nil) {
        enterScope()
        defer { leaveScope() }
        var notice: (names: [String], focused: Int)?
        if running, config.enabled, config.workspaces.count > 1 {
            let screens = currentScreens()
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
        enterScope()
        defer { leaveScope() }
        guard running, config.enabled, config.workspaces.count > 1 else { return [] }
        syncDisplays()
        let screens = currentScreens()
        var apps: [pid_t: NSRunningApplication] = [:]
        return (0..<workspaceCount).map { index in
            let members = orderedWindows.filter { $0.workspace == index && !$0.scratchpad }
            let entries = members.map { window -> WorkspaceSummary.Window in
                let app = apps[window.pid] ?? NSRunningApplication(processIdentifier: window.pid)
                apps[window.pid] = app
                let title = AX.string(window.element, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
                return WorkspaceSummary.Window(app: app?.localizedName ?? window.bundleID ?? "App",
                                               title: title, icon: app?.icon)
            }
            let display = display(showing: index).flatMap { id in screens.firstIndex { $0.id == id } }.map { $0 + 1 }
            return WorkspaceSummary(index: index, name: name(of: index), display: display, windows: entries)
        }
    }

    // MARK: - Commands

    private func focused() -> ManagedWindow? {
        if let scope, scope.focusedRead { return scope.focused }
        let window = readFocused()
        if scope != nil {
            scope?.focusedRead = true
            scope?.focused = window
        }
        return window
    }

    /// Asks the frontmost app for its focused window (a synchronous AX round trip).
    private func readFocused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element) else { return nil }
        return windows[id]
    }

    /// The display the user works on: the focused window's, else the one we last moved the
    /// focus to (an empty workspace has no window), else the one under the pointer.
    private func focusedScreen(_ focusedWindow: ManagedWindow?? = nil) -> ScreenInfo? {
        let screens = currentScreens()
        guard !screens.isEmpty else { return nil }
        // On an empty workspace the window left behind may still look focused.
        if let id = heldDisplay, let screen = screens.first(where: { $0.id == id }) { return screen }
        if let window = focusedWindow ?? focused(), window.hiddenFrame == nil, display(showing: window.workspace) != nil,
           let frame = currentBounds()[window.id] {
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
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let current = focused(), let origin = bounds[current.id] else { return }
        // Accordion: left and right go through the stack in order (the windows overlap, so
        // their centers say little); past either end, on to the next display.
        if let next = accordionNeighbor(of: current, direction, bounds) {
            focus(next)
            return
        }
        let candidates = visible(bounds).filter { $0.0.id != current.id }
        if let target = Layout.neighbor(of: origin, direction, among: candidates) { focus(target) }
    }

    /// The previous or next tiled window of an accordion, for left and right.
    private func accordionNeighbor(of window: ManagedWindow, _ direction: Direction, _ bounds: [CGWindowID: CGRect]) -> ManagedWindow? {
        let kind = layout(of: window.workspace)
        guard direction == .left || direction == .right, !window.isFloating, !window.scratchpad,
              inAccordion(window, layout: kind) else { return nil }
        if kind == .columns {
            return columns[window.workspace]?.accordionNeighbor(of: window.id, direction == .right ? 1 : -1)
                .flatMap { windows[$0] }.flatMap { bounds[$0.id] == nil ? nil : $0 }
        }
        let tiled = tiledWindows(in: window.workspace, bounds: bounds)
        guard let index = tiled.firstIndex(where: { $0 === window }) else { return nil }
        let next = index + (direction == .right ? 1 : -1)
        return tiled.indices.contains(next) ? tiled[next] : nil
    }

    /// Whether a tiled window is shown in an accordion: the accordion layout, a workspace
    /// stacked with `accordion`, or (columns) an accordion column.
    private func inAccordion(_ window: ManagedWindow, layout kind: LayoutKind) -> Bool {
        switch kind {
        case .accordion: return true
        case .columns: return columns[window.workspace]?.isInAccordion(window.id) ?? false
        case .tall, .wide, .monocle: return accordionWorkspaces.contains(window.workspace)
        }
    }

    /// Stacks the focused window's workspace as an accordion, or unstacks it. In columns the
    /// windows become one accordion column: move a window left or right (`swap`) to take it
    /// out into a column of its own, up or down to reorder the stack. In tall, wide and monocle
    /// the whole workspace is stacked, and any move puts it back in its layout.
    func toggleAccordion() {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard running, let window = focused(), !window.isFloating, !window.scratchpad, bounds[window.id] != nil else { return }
        let workspace = window.workspace
        lastFocused[workspace] = window.id
        switch layout(of: workspace) {
        case .accordion:
            return
        case .columns:
            var layout = columns[workspace] ?? ColumnLayout()
            layout.sync(with: tiledWindows(in: workspace, bounds: bounds).map(\.id))
            let on = layout.toggleAccordion(around: window.id)
            columns[workspace] = layout
            log.debug("accordion \(on ? "on" : "off") in workspace \(workspace)")
        case .tall, .wide, .monocle:
            if accordionWorkspaces.remove(workspace) == nil { accordionWorkspaces.insert(workspace) }
        }
        retile()
        focus(window)
    }

    /// The layout of the display showing a workspace.
    private func layout(of workspace: Int) -> LayoutKind {
        state(for: display(showing: workspace)).layout
    }

    func swap(_ direction: Direction) {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let current = focused(), !current.isFloating, let origin = bounds[current.id] else { return }
        if layout(of: current.workspace) == .columns, columns[current.workspace]?.locate(current.id) != nil {
            // Columns: stack, unstack and reorder (see ColumnLayout.move); new arrangement, even shares.
            columns[current.workspace]?.move(current.id, direction)
            current.weight = 1
            retile()
            return
        }
        if accordionWorkspaces.contains(current.workspace), layout(of: current.workspace) != .columns {
            // Stacked on top of tall, wide or monocle: a move puts the windows back in the layout.
            accordionWorkspaces.remove(current.workspace)
            retile()
            return
        }
        if let neighbor = accordionNeighbor(of: current, direction, bounds) {
            swapOrder(current.id, neighbor.id)
            Swift.swap(&current.weight, &neighbor.weight)
            retile()
            return
        }
        let candidates = visible(bounds, tiledOnly: true).filter { $0.0.id != current.id }
        guard let target = Layout.neighbor(of: origin, direction, among: candidates), let targetFrame = bounds[target.id] else { return }
        swapOrder(current.id, target.id)
        Swift.swap(&current.weight, &target.weight)
        Swift.swap(&current.workspace, &target.workspace)
        // Exchanging frames also carries the windows across displays.
        setFrame(current, targetFrame, from: origin)
        setFrame(target, origin, from: targetFrame)
        scheduleRetile()
    }

    func swapMaster() {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
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

    func adjustRatio(_ delta: CGFloat) {
        updateActiveScreen { $0.ratio = ($0.ratio + delta).clamped(to: TilingConfig.ratioRange) }
    }

    /// Grows or shrinks the focused window by `delta` points. Floating windows are
    /// resized directly; tiled ones move the master/stack split or change their share
    /// of the stack (or of the columns).
    func resizeFocused(width isWidth: Bool, by delta: CGFloat) {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let window = focused(), let frame = bounds[window.id] else { return }
        if window.isFloating {
            var resized = frame
            if isWidth {
                resized.size.width = max(Self.minimumWindowSize.width, frame.width + delta)
            } else {
                resized.size.height = max(Self.minimumWindowSize.height, frame.height + delta)
            }
            setFrame(window, resized)
            return
        }
        let screens = currentScreens()
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
                state.ratio = (state.ratio + (position == 0 ? change : -change)).clamped(to: TilingConfig.ratioRange)
                setState(state, for: screen.id)
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
        case .monocle, .accordion:
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
        enterScope()
        defer { leaveScope() }
        guard let window = focused() else { return }
        window.isFloating.toggle()
        window.userOverride = true
        if window.isFloating { focus(window) }
        scheduleRetile()
    }

    /// Moves the focused workspace, windows and arrangement, to the next display, where it
    /// replaces the workspace shown there (which stays intact, just hidden). The display it
    /// leaves goes back to the last of its own workspaces it showed, or to none.
    func moveWorkspaceToNextDisplay() {
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard running, screens.count > 1, let source = focusedScreen(), let workspace = displayed[source.id],
              let sourceIndex = screens.firstIndex(where: { $0.id == source.id }) else { return }
        let target = screens[(sourceIndex + 1) % screens.count]
        ignoreFocusChanges()
        if let window = focused(), window.workspace == workspace { lastFocused[workspace] = window.id }

        homeOverride[workspace] = target.uuid
        showWorkspace(workspace, on: target.id)
        let remaining = (0..<workspaceCount).filter { $0 != workspace && home(of: $0, screens)?.id == source.id }
        let back = Self.workspaceLeftBehind(remaining: remaining, shownBefore: shownBefore[source.id])
        showWorkspace(back, on: source.id)
        log.debug("move workspace \(workspace) from display \(source.id) to \(target.id); display \(source.id) now shows \(back ?? -1)")
        carryFloating(windows.values.filter { $0.workspace == workspace }, screens: screens)
        retile()
        let focusedWindow = focusWindow(in: workspace)
        notifyWorkspace(focused: .some(focusedWindow))
    }

    /// What a display shows once its workspace moved away: the last of its own it showed, or
    /// its first, or nothing when no workspace lives there any more.
    static func workspaceLeftBehind(remaining: [Int], shownBefore: Int?) -> Int? {
        shownBefore.flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.first
    }

    /// Focuses the workspace shown on the next display.
    func focusNextDisplay() {
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard screens.count > 1, let current = focusedScreen(),
              let index = screens.firstIndex(where: { $0.id == current.id }) else { return }
        guard let workspace = displayed[screens[(index + 1) % screens.count].id] else { return notifyWorkspace() }
        let window = focusWindow(in: workspace)
        notifyWorkspace(focused: .some(window))
    }

    // MARK: - Mouse drag (modifier + left drag moves, modifier + right drag resizes)

    func beginDrag(_ mode: DragMode, at point: CGPoint) {
        guard let element = AX.window(at: point),
              let origin = AX.position(element), let size = AX.size(element) else { return }
        // Focus and moves go through the app's AX queue, in order, off the main thread.
        let pid = AX.pid(element)
        writer.perform(pid) { AX.focus(element, pid: pid) }
        dragGeneration += 1
        dragWriteInFlight = false
        dragPendingPoint = nil
        drag = DragSession(mode: mode, element: element, pid: pid, id: AX.windowID(element), start: point,
                           frame: CGRect(origin: origin, size: size))
    }

    func updateDrag(to point: CGPoint) {
        guard let drag else { return }
        // One write at a time: while the app is busy only the newest point waits.
        if dragWriteInFlight {
            dragPendingPoint = point
        } else {
            writeDrag(drag, to: point)
        }
    }

    private func writeDrag(_ session: DragSession, to point: CGPoint) {
        dragWriteInFlight = true
        let generation = dragGeneration
        let dx = point.x - session.start.x
        let dy = point.y - session.start.y
        let element = session.element
        let frame = session.frame
        let mode = session.mode
        writer.perform(session.pid) { [weak self] in
            switch mode {
            case .move:
                AX.setPosition(element, CGPoint(x: frame.minX + dx, y: frame.minY + dy))
            case .resize:
                let minimum = WindowManager.minimumWindowSize
                AX.setSize(element, CGSize(width: max(minimum.width, frame.width + dx), height: max(minimum.height, frame.height + dy)))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == dragGeneration else { return }
                dragWriteInFlight = false
                // The point that arrived meanwhile is written even if the button was released.
                if let next = dragPendingPoint {
                    dragPendingPoint = nil
                    writeDrag(session, to: next)
                }
            }
        }
    }

    func endDrag(at point: CGPoint) {
        enterScope()
        defer { leaveScope() }
        guard let session = drag else { return }
        drag = nil
        guard running, let id = session.id, let window = windows[id], !window.isFloating else { return }

        let bounds = currentBounds()
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
            } else if let screen = currentScreens().first(where: { $0.frame.contains(point) }),
                      let workspace = displayed[screen.id] {
                window.workspace = workspace
            }
        case .resize:
            // Resizing a tiled window drags the master/stack split instead.
            let screens = currentScreens()
            guard let frame = bounds[id], !screens.isEmpty else { break }
            let screen = screens[screens.index(for: frame)]
            var state = state(for: screen.id)
            let isMaster = tiledWindows(in: window.workspace, bounds: bounds).first === window
            let delta: CGFloat
            switch state.layout {
            case .tall: delta = (point.x - session.start.x) / screen.visible.width
            case .wide: delta = (point.y - session.start.y) / screen.visible.height
            case .columns, .monocle, .accordion: delta = 0
            }
            state.ratio = (state.ratio + (isMaster ? delta : -delta)).clamped(to: TilingConfig.ratioRange)
            setState(state, for: screen.id)
        }
        scheduleRetile()
    }
}
