import AppKit
import ApplicationServices

final class ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    var isFloating = false
    /// A dialog-like window (no zoom, no full screen): always floats unless toggled by hand.
    var isDialog = false
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
    /// Called when tiling is turned on or off by the toggle-tiling action.
    var onEnabledChange: ((Bool) -> Void)?
    /// Until then apps opened with a rule do not take you to their workspace: they are the
    /// apps macOS reopens at login, not ones you open. Set when HyperSpace starts at login.
    var revealAfter = Date.distantPast

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
        let byTitle = !config.floatingWindows.isEmpty
        for window in windows.values where !window.userOverride {
            window.isFloating = window.isDialog
                || config.floats(app: window.bundleID, title: byTitle ? AX.string(window.element, kAXTitleAttribute) : nil)
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

        // Window elements use the global AX timeout (6 s by default): an app still busy
        // launching at login must not stall the window manager that long.
        _ = AX.systemWide
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

    /// Remembers the workspace an app is being opened from, the first time it is seen.
    private func noteLaunch(_ app: NSRunningApplication) {
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
            adopting = false
            applyRestoredLayout()
            rescueStrandedWindows()
            scheduleRetile()
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
        apps.values.forEach { $0.invalidate() }
        apps.removeAll()
        launches.removeAll()
        adopting = false
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
            if attempt == 0 || attempt == 19 { note("cannot watch \(app.bundleIdentifier ?? "?") yet (attempt \(attempt + 1))") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.addApp(app, attempt: attempt + 1)
            }
        }
    }

    private func removeApp(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.invalidate()
        writer.forget(pid)
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
            note("no window id for a window of \(watcher.bundleID ?? "?") (role \(AX.string(element, kAXRoleAttribute) ?? "-"))")
            return nil
        }
        guard windows[id] == nil else { return nil }
        guard AX.isStandardWindow(element) else {
            log.debug("skip window of \(watcher.bundleID ?? "?", privacy: .public): role \(AX.string(element, kAXRoleAttribute) ?? "-", privacy: .public) subrole \(AX.string(element, kAXSubroleAttribute) ?? "-", privacy: .public)")
            return nil
        }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isDialog = AX.isDialogLike(element)
        window.isFloating = window.isDialog
            || config.floats(app: watcher.bundleID, title: config.floatingWindows.isEmpty ? nil : AX.string(element, kAXTitleAttribute))
        // Right after start, the window this one was before HyperSpace (or the Mac) restarted.
        var restored: WorkspaceState.Window?
        if restorer != nil, let app = watcher.bundleID,
           let index = restorer?.claim(app: app, title: AX.string(element, kAXTitleAttribute)) {
            restored = restorer?.window(index)
            restoredIndex[id] = index
            if let floating = restored?.floating {
                window.isFloating = floating
                window.userOverride = true
            }
            window.scratchpad = restored?.scratchpad ?? false
        }
        // The app was opened by its scratchpad shortcut: this window is the scratchpad one.
        if let app = watcher.bundleID, let until = pendingScratchpad[app] {
            pendingScratchpad[app] = nil
            if Date() < until {
                window.scratchpad = true
                DispatchQueue.main.async { [weak self] in self?.showScratchpad(window) }
            }
        }
        // A window joins its app's assigned workspace, the one it had before a restart, the
        // one the app was opened from (you may have moved on while it loaded), or the one
        // shown where it appears.
        let launch = launches.workspace(for: watcher.pid)
        let assigned = watcher.bundleID.flatMap { config.assignments[$0] }
        window.workspace = Self.newWindowWorkspace(assigned: assigned, restored: restored?.workspace, launch: launch,
                                                   workspaces: workspaceCount) { [self] in
            if let origin = AX.position(element), let size = AX.size(element), case let screens = ScreenInfo.current(), !screens.isEmpty {
                return displayed[screens[screens.index(for: CGRect(origin: origin, size: size))].id]
            }
            return focusedScreen().flatMap { displayed[$0.id] }
        }
        // An app with a rule you just opened takes you to its workspace, however its first
        // window was found (an app slow to answer is picked up by a later look).
        if let assigned, assigned < workspaceCount, launch != nil, restored == nil, !window.scratchpad { reveal(window) }
        windows[id] = window
        order.append(id)
        watcher.watch(element)
        log.debug("track \(watcher.bundleID ?? "?", privacy: .public) window \(id) workspace \(window.workspace) floating \(window.isFloating)")
        return window
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
                      focused()?.id != window.id, onScreenBounds()[window.id] != nil else { return }
                focus(window)
            }
        }
    }

    // MARK: - Scratchpad

    /// Shows or hides an app's scratchpad window, opening the app (or a window of it) first
    /// when needed; with no app, the windows sent to the scratchpad.
    func toggleScratchpad(app name: String?) {
        guard running else { return }
        let focusedID = focused()?.id
        guard let name else {
            let pad = order.compactMap { windows[$0] }.filter(\.scratchpad)
            if let shown = pad.first(where: { $0.scratchpadShown && $0.id == focusedID }) {
                hideScratchpad(shown)
            } else if let shown = pad.first(where: \.scratchpadShown) {
                focus(shown)
            } else if let hidden = pad.first {
                showScratchpad(hidden)
            }
            return
        }
        guard let bundleID = AppLauncher.bundleID(for: name) else {
            note("scratchpad: app not found: \(name)")
            return
        }
        let mine = order.compactMap { windows[$0] }.filter { $0.bundleID == bundleID }
        if let window = mine.first(where: \.scratchpad) {
            if window.scratchpadShown, window.id == focusedID { hideScratchpad(window) } else { showScratchpad(window) }
        } else if let window = mine.first(where: { $0.id == focusedID }) ?? mine.first {
            // Already open in the tiling: it moves to the scratchpad.
            window.scratchpad = true
            showScratchpad(window)
        } else {
            // Not open, or no window: its next window is the scratchpad one.
            pendingScratchpad[bundleID] = Date().addingTimeInterval(30)
            AppLauncher.open(name)
        }
    }

    /// The focused window, or with an app that app's window, goes into the scratchpad (shown),
    /// or from it into the tiling of the workspace you are on. An app not open is opened.
    func moveToScratchpad(app name: String?) {
        guard running else { return }
        guard let name else {
            if let window = focused() { toggleScratchpadTiling(window) }
            return
        }
        guard let bundleID = AppLauncher.bundleID(for: name) else {
            note("scratchpad: app not found: \(name)")
            return
        }
        let mine = order.compactMap { windows[$0] }.filter { $0.bundleID == bundleID }
        let focusedID = focused()?.id
        if let window = mine.first(where: \.scratchpad) ?? mine.first(where: { $0.id == focusedID }) ?? mine.first {
            toggleScratchpadTiling(window)
        } else {
            AppLauncher.open(name)
        }
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
        let screens = ScreenInfo.current()
        guard let screen = focusedScreen() ?? screens.first else { return }
        ignoreFocusChanges()
        let target = Self.scratchpadFrame(in: screen.visible, size: config.scratchpadSize)
        let frame = scratchpadFitted.flatMap { $0.target == target ? Self.centered($0.size, in: target) : nil } ?? target
        let current = onScreenBounds()[window.id]
        log.debug("show scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) on display \(screen.id)")
        window.scratchpadShown = true
        window.hiddenFrame = nil
        setFrame(window, frame, from: current, screens: screens)
        // Apps that size in steps (terminals) or have a minimum size miss the exact size:
        // centered on what they took, and the other scratchpad windows take it too.
        let element = window.element
        let misses = { (size: CGSize) in abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1 }
        writer.perform(window.pid) { [weak self] in
            guard var size = AX.size(element) else { return }
            // Coming from another display, some apps resize themselves a moment after the
            // move (a different scale): ask again before taking their size as their best.
            if misses(size) {
                Thread.sleep(forTimeInterval: 0.1)
                AX.setSize(element, frame.size)
                size = AX.size(element) ?? size
            }
            guard let origin = AX.position(element) else { return }
            if misses(size) {
                DispatchQueue.main.async { self?.scratchpadFitted = (target, size) }
            }
            let centered = Self.centered(size, in: target)
            if abs(origin.x - centered.minX) > 1 || abs(origin.y - centered.minY) > 1 {
                AX.setPosition(element, centered.origin)
            }
        }
        focus(window)
        notifyWorkspace()
    }

    private func hideScratchpad(_ window: ManagedWindow) {
        ignoreFocusChanges()
        window.scratchpadShown = false
        let screens = ScreenInfo.current()
        if let frame = onScreenBounds()[window.id] { hide(window, from: frame, screens: screens) }
        log.debug("hide scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public))")
        // Back to what you were doing.
        if let workspace = activeDisplay.flatMap({ displayed[$0] }) ?? screens.first.flatMap({ displayed[$0.id] }) {
            focusWindow(in: workspace)
        }
    }

    /// Centered in the visible area, `size` being fractions of it.
    static func scratchpadFrame(in visible: CGRect, size: CGSize) -> CGRect {
        let width = (visible.width * size.width).rounded()
        let height = (visible.height * size.height).rounded()
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    /// A window of `size` centered on the scratchpad `frame`.
    static func centered(_ size: CGSize, in frame: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()),
               size: size)
    }

    // MARK: - Debug report

    private func note(_ issue: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        issues.append("\(time) \(issue)")
        if issues.count > 30 { issues.removeFirst(issues.count - 30) }
    }

    /// What the window manager knows, to paste when something goes wrong. Reads titles.
    func debugReport() -> String {
        var lines: [String] = []
        lines.append("Tiling: \(running ? "running" : "stopped"), enabled \(config.enabled), layout \(config.layout.rawValue)")
        let screens = ScreenInfo.current()
        let focusedID = focusedScreen()?.id
        for (i, screen) in screens.enumerated() {
            let shown = displayed[screen.id].map { "\(name(of: $0)) (#\($0 + 1))" } ?? "none"
            lines.append("Display \(i + 1): id \(screen.id) \(Self.describe(screen.frame)) shows \(shown)\(screen.id == focusedID ? " [focused]" : "")")
        }
        if !homeOverride.isEmpty {
            lines.append("Moved workspaces: " + homeOverride.sorted { $0.key < $1.key }.map { "\(name(of: $0.key)) → display \($0.value)" }.joined(separator: ", "))
        }
        let bounds = onScreenBounds()
        for workspace in 0..<workspaceCount {
            let members = order.compactMap { windows[$0] }.filter { $0.workspace == workspace }
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
        let ids = Set(ScreenInfo.current().map(\.id))
        for (key, display) in state.homeOverride {
            if let workspace = Int(key), workspace < workspaceCount, ids.contains(display) { homeOverride[workspace] = display }
        }
        for (key, workspace) in state.displayed {
            if let display = CGDirectDisplayID(key), ids.contains(display), workspace < workspaceCount { displayed[display] = workspace }
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
            columns[workspace] = ColumnLayout(columns: saved.map { $0.compactMap { idByIndex[$0] } })
        }
    }

    /// The state to save, without titles (read later, off the main thread), and the windows
    /// whose titles go with it.
    private func currentState() -> (state: WorkspaceState, elements: [AXUIElement]) {
        let list = order.compactMap { windows[$0] }.filter { $0.bundleID != nil }
        var index: [CGWindowID: Int] = [:]
        var state = WorkspaceState(savedAt: .distantPast)
        for (i, window) in list.enumerated() {
            index[window.id] = i
            state.windows.append(.init(app: window.bundleID!, title: "", workspace: window.workspace,
                                       floating: window.userOverride ? window.isFloating : nil,
                                       scratchpad: window.scratchpad ? true : nil))
        }
        for (workspace, layout) in columns {
            let saved = layout.columns.map { $0.windows.compactMap { index[$0] } }.filter { !$0.isEmpty }
            if !saved.isEmpty { state.columns[String(workspace)] = saved }
        }
        for (display, workspace) in displayed { state.displayed[String(display)] = workspace }
        for (workspace, display) in homeOverride { state.homeOverride[String(workspace)] = display }
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
        applyRestoredLayout()
        scheduleRetile()
    }

    func handle(_ notification: String, element: AXUIElement) {
        guard running else { return }
        let pid = AX.pid(element)
        switch notification {
        case kAXWindowCreatedNotification:
            guard let watcher = apps[pid], let window = track(element, in: watcher) else { return }
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

    /// The tracked window of an AX element, compared locally (asking the app for the
    /// window id would be a round trip, and a destroyed element has none left).
    private func managed(_ element: AXUIElement, pid: pid_t) -> ManagedWindow? {
        windows.values.first { $0.pid == pid && CFEqual($0.element, element) }
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
                if !(bounds[window.id]?.isClose(to: frame) ?? false) { setFrame(window, frame, from: bounds[window.id], screens: screens) }
            }
        }
        scheduleSave()
    }

    private func area(of screen: ScreenInfo) -> CGRect {
        screen.visible.insetBy(dx: config.padding, dy: config.padding)
    }

    /// Tiled windows of a workspace that are on screen, in tiling order.
    private func tiledWindows(in workspace: Int, bounds: [CGWindowID: CGRect]) -> [ManagedWindow] {
        order.compactMap { windows[$0] }.filter {
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
    private func focus(_ window: ManagedWindow) {
        ignoreFocusChanges()
        focusRequest += 1
        let request = focusRequest
        writer.perform(window.pid) { AX.focus(window.element, pid: window.pid) }
        let screens = ScreenInfo.current()
        if let frame = onScreenBounds()[window.id], !screens.isEmpty {
            let screen = screens[screens.index(for: frame)]
            activeDisplay = screen.id
            bringPointer(to: frame.center, on: screen, screens)
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

    /// Moves the pointer to `point` when it is on another display than `screen`.
    private func bringPointer(to point: CGPoint, on screen: ScreenInfo, _ screens: [ScreenInfo]) {
        guard config.mouseFollowsFocus, !screen.frame.contains(AX.pointer) else { return }
        AX.warpPointer(to: point)
    }

    /// `current`, when known, lets a move within a display skip the writes it does not need.
    private func setFrame(_ window: ManagedWindow, _ frame: CGRect, from current: CGRect? = nil, screens: [ScreenInfo]? = nil) {
        window.movedByUs = Date()
        let sameDisplay = current.map { Self.sameDisplay($0, frame, screens ?? ScreenInfo.current()) } ?? false
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
            if failure != .success {
                DispatchQueue.main.async { self?.note("moving a window of \(name) failed: AX error \(failure.rawValue)") }
            }
            if enhanced, let app { AX.setBool(app, "AXEnhancedUserInterface", true) }
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
        let id = Self.homeDisplay(of: workspace, movedTo: homeOverride[workspace], displays: screens.map(\.id))
        return screens.first { $0.id == id }
    }

    /// `displays` in `ScreenInfo.current()` order; a move to a display no longer there is ignored.
    static func homeDisplay(of workspace: Int, movedTo: CGDirectDisplayID?, displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if let movedTo, displays.contains(movedTo) { return movedTo }
        return displays.isEmpty ? nil : displays[homeIndex(of: workspace, displays: displays.count)]
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
        let ids = ScreenInfo.current().map(\.id)
        displayed = Self.syncedDisplays(displayed, displays: ids, workspaces: workspaceCount) { [homeOverride] in
            Self.homeDisplay(of: $0, movedTo: homeOverride[$0], displays: ids)
        }
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
        let element = window.element
        writer.perform(window.pid) { AX.setPosition(element, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)) }
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    private func show(_ window: ManagedWindow, on screen: ScreenInfo) {
        guard let frame = window.hiddenFrame else { return }
        setFrame(window, screen.frame.contains(frame.center) ? frame : screen.centered(frame.size))
        window.hiddenFrame = nil
    }

    /// Focuses the workspace: its last focused window, or with no windows, its display.
    /// Returns the window it focuses (nil for the display alone).
    @discardableResult
    private func focusWindow(in workspace: Int) -> ManagedWindow? {
        let bounds = onScreenBounds()
        let candidates = order.compactMap { windows[$0] }.filter {
            $0.workspace == workspace && !$0.scratchpad && bounds[$0.id] != nil
        }
        if let target = candidates.first(where: { $0.id == lastFocused[workspace] }) ?? candidates.first {
            focus(target)
            return target
        } else if let id = display(showing: workspace), case let screens = ScreenInfo.current(),
                  let screen = screens.first(where: { $0.id == id }) {
            activeDisplay = id
            bringPointer(to: screen.visible.center, on: screen, screens)
            // Nothing to focus there: take the keyboard away from the window you left (on
            // another display it would keep typing there). HyperSpace has no window to show.
            // Through AX like any other app: NSApp.activate is ignored from the background.
            // Off the main thread, which has to answer the request.
            focusRequest += 1
            let me = getpid()
            writer.perform(me) { AX.setBool(AXUIElementCreateApplication(me), kAXFrontmostAttribute, true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                log.debug("empty workspace \(workspace): frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public)")
            }
        }
        return nil
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    private func followFocus(_ window: ManagedWindow?) {
        guard running, let window else { return }
        if window.scratchpad {
            // ⌘Tab or the Dock to a hidden scratchpad window: show it instead of a workspace.
            if !window.scratchpadShown, Date() > followFocusAfter { showScratchpad(window) }
            return
        }
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
            let members = order.compactMap { windows[$0] }.filter { $0.workspace == index && !$0.scratchpad }
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
            notifyWorkspace(focused: .some(window))
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

    /// Layout of the display with the focus, for the menu; nil while tiling is off.
    var activeLayout: LayoutKind? {
        guard running, config.enabled, let id = focusedScreen()?.id else { return nil }
        return state(for: id).layout
    }

    func setLayout(_ kind: LayoutKind) {
        updateActiveScreen { $0.layout = kind }
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
        let back = Self.workspaceLeftBehind(remaining: remaining, shownBefore: shownBefore[source.id])
        show(back, on: source.id)
        log.debug("move workspace \(workspace) from display \(source.id) to \(target.id); display \(source.id) now shows \(back ?? -1)")
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
        let screens = ScreenInfo.current()
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
