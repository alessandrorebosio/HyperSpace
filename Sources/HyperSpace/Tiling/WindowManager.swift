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

/// Event-driven tiling window manager with virtual workspaces.
///
/// - Window lifecycle comes from AX observers and NSWorkspace notifications (no polling).
/// - Which windows are visible (current Space, not minimized, app not hidden) and where
///   they are is read from one `CGWindowListCopyWindowInfo` call per retile, which needs
///   no Screen Recording permission as long as window titles are not requested.
/// - Frames are only written when they differ from the target, so a retile with
///   nothing to do costs a single window-server query.
/// - Workspaces are virtual (macOS offers no public API to drive Spaces) and, as in i3,
///   each display shows one of them. Every window belongs to a workspace; windows of
///   workspaces not shown anywhere are parked in the bottom-right corner of their screen.
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
    /// Column arrangement of each workspace (columns layout).
    private var columns: [Int: ColumnLayout] = [:]
    private var previousWorkspace: Int?
    private var lastFocused: [Int: CGWindowID] = [:]
    /// Focus changes we cause ourselves must not switch workspace back.
    private var followFocusAfter = Date.distantPast

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
            followFocus()
            notifyWorkspace()
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
        windows.removeAll()
        order.removeAll()
        lastFocused.removeAll()
        displayed.removeAll()
    }

    /// After a crash windows can be left parked off-screen: bring them back.
    private func rescueStrandedWindows() {
        let screens = ScreenInfo.current()
        guard let main = screens.first else { return }
        for (id, frame) in onScreenBounds() {
            guard let window = windows[id] else { continue }
            let visible = screens.map { $0.frame.intersection(frame) }.map { $0.isNull ? 0 : $0.width * $0.height }.max() ?? 0
            guard visible < frame.width * frame.height * 0.1 else { continue }
            let size = CGSize(width: min(frame.width, main.visible.width), height: min(frame.height, main.visible.height))
            setFrame(window, CGRect(x: main.visible.midX - size.width / 2, y: main.visible.midY - size.height / 2,
                                    width: size.width, height: size.height))
        }
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
        guard let id = AX.windowID(element), windows[id] == nil else { return false }
        guard AX.isStandardWindow(element) else {
            log.debug("skip window of \(watcher.bundleID ?? "?", privacy: .public): role \(AX.string(element, kAXRoleAttribute) ?? "-", privacy: .public) subrole \(AX.string(element, kAXSubroleAttribute) ?? "-", privacy: .public)")
            return false
        }
        let window = ManagedWindow(id: id, element: element, pid: watcher.pid, bundleID: watcher.bundleID)
        window.isFloating = config.floating.contains(watcher.bundleID ?? "")
        // A window joins its app's assigned workspace, or the one shown where it appears.
        let screens = ScreenInfo.current()
        if let assigned = watcher.bundleID.flatMap({ config.assignments[$0] }), assigned < workspaceCount {
            window.workspace = assigned
        } else if let origin = AX.position(element), let size = AX.size(element), !screens.isEmpty {
            let screen = screens[screens.index(for: CGRect(origin: origin, size: size))]
            window.workspace = displayed[screen.id] ?? 0
        } else {
            window.workspace = focusedScreen().flatMap { displayed[$0.id] } ?? 0
        }
        windows[id] = window
        order.append(id)
        watcher.watchDestroyed(element)
        log.debug("track \(watcher.bundleID ?? "?", privacy: .public) window \(id) workspace \(window.workspace) floating \(window.isFloating)")
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
            // An app you just opened shows its assigned workspace, so its window is visible.
            if let id = AX.windowID(element), let window = windows[id], display(showing: window.workspace) == nil,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                lastFocused[window.workspace] = id
                switchWorkspace(window.workspace)
                return
            }
            scheduleRetile()
            // Some apps put the window on screen a moment after announcing it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scheduleRetile() }
        case kAXUIElementDestroyedNotification:
            guard let id = windows.first(where: { $0.value.pid == pid && CFEqual($0.value.element, element) })?.key else { return }
            untrack(id)
            scheduleRetile()
        case kAXFocusedWindowChangedNotification:
            followFocus()
            notifyWorkspace()
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
        syncDisplays()
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return }
        let bounds = onScreenBounds()
        let shown = Set(displayed.values)

        for window in windows.values {
            if !shown.contains(window.workspace) {
                if window.hiddenFrame == nil, let frame = bounds[window.id] { hide(window, from: frame) }
            } else if window.isFloating, let screen = screens.first(where: { displayed[$0.id] == window.workspace }) {
                show(window, on: screen)
            }
        }

        for screen in screens {
            guard let workspace = displayed[screen.id] else { continue }
            let tiled = order.compactMap { windows[$0] }.filter { window in
                guard window.workspace == workspace, !window.isFloating, let frame = bounds[window.id] else { return false }
                // A native full-screen window covers the whole display, menu bar included.
                return window.hiddenFrame != nil || !screens.contains { frame.isClose(to: $0.frame) }
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
        guard let id = focusedScreen()?.id else { return }
        var state = state(for: id)
        change(&state)
        screenStates[id] = state
        scheduleRetile()
    }

    // MARK: - Workspaces

    /// Every display shows a workspace; new displays take the first free one.
    private func syncDisplays() {
        let screens = ScreenInfo.current()
        let ids = Set(screens.map(\.id))
        displayed = displayed.filter { ids.contains($0.key) }
        for screen in screens where displayed[screen.id] == nil {
            let used = Set(displayed.values)
            displayed[screen.id] = (0..<workspaceCount).first { !used.contains($0) } ?? 0
        }
    }

    private func display(showing workspace: Int) -> CGDirectDisplayID? {
        displayed.first { $0.value == workspace }?.key
    }

    /// Shows a workspace. Already on a display: focus moves there (as in i3); otherwise
    /// it replaces the workspace of the focused display.
    func switchWorkspace(_ index: Int) {
        guard running, (0..<workspaceCount).contains(index) else { return }
        syncDisplays()
        if display(showing: index) != nil {
            focusWindow(in: index)
            notifyWorkspace()
            return
        }
        guard let screen = focusedScreen(), let current = displayed[screen.id] else { return }
        if let window = focused(), window.workspace == current { lastFocused[current] = window.id }
        displayed[screen.id] = index
        previousWorkspace = current
        retile()
        focusWindow(in: index)
        notifyWorkspace()
    }

    func switchToPreviousWorkspace() {
        if let previousWorkspace { switchWorkspace(previousWorkspace) }
    }

    func moveFocusedWindow(toWorkspace index: Int) {
        guard running, (0..<workspaceCount).contains(index), let window = focused(), window.workspace != index else { return }
        let source = window.workspace
        window.workspace = index
        retile()
        if display(showing: index) == nil { focusWindow(in: source) }
    }

    /// Parks a window in the bottom-right corner of its screen, nearly all of it off-screen.
    private func hide(_ window: ManagedWindow, from frame: CGRect) {
        guard window.hiddenFrame == nil else { return }
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return }
        window.hiddenFrame = frame
        let screen = screens[screens.index(for: frame)].frame
        AX.setPosition(window.element, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1))
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    private func show(_ window: ManagedWindow, on screen: ScreenInfo) {
        guard var frame = window.hiddenFrame else { return }
        if !screen.frame.contains(frame.center) {
            frame.origin = CGPoint(x: screen.visible.midX - frame.width / 2, y: screen.visible.midY - frame.height / 2)
        }
        setFrame(window, frame)
        window.hiddenFrame = nil
    }

    private func focusWindow(in workspace: Int) {
        followFocusAfter = Date().addingTimeInterval(0.6)
        let bounds = onScreenBounds()
        let candidates = order.compactMap { windows[$0] }.filter { $0.workspace == workspace && bounds[$0.id] != nil }
        let target = candidates.first { $0.id == lastFocused[workspace] } ?? candidates.first
        if let target { AX.focus(target.element, pid: target.pid) }
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    private func followFocus() {
        guard running, Date() > followFocusAfter, let window = focused(),
              display(showing: window.workspace) == nil else { return }
        switchWorkspace(window.workspace)
    }

    private func notifyWorkspace() {
        guard running, config.enabled, config.workspaces.count > 1 else {
            onWorkspaceChange?(nil)
            return
        }
        let screens = ScreenInfo.current()
        let names = screens.map { displayed[$0.id].map(name(of:)) ?? "–" }
        let focusedID = focusedScreen()?.id
        onWorkspaceChange?((names, screens.firstIndex { $0.id == focusedID } ?? 0))
    }

    // MARK: - Commands

    private func focused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element) else { return nil }
        return windows[id]
    }

    /// The display with the focused window, or under the pointer when nothing is focused.
    private func focusedScreen() -> ScreenInfo? {
        let screens = ScreenInfo.current()
        guard !screens.isEmpty else { return nil }
        if let window = focused(), window.hiddenFrame == nil, let frame = onScreenBounds()[window.id] {
            return screens[screens.index(for: frame)]
        }
        let mouse = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: mouse.x, y: height - mouse.y)
        return screens.first { $0.frame.contains(point) } ?? screens.first
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
        if let target = Layout.neighbor(of: origin, direction, among: candidates) {
            AX.focus(target.element, pid: target.pid)
        }
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
        let screens = ScreenInfo.current()
        guard let current = focused(), !current.isFloating, let frame = bounds[current.id] else { return }
        let screen = screens.index(for: frame)
        let master = order.first { id in
            guard let w = windows[id], w.workspace == current.workspace, !w.isFloating, let f = bounds[id] else { return false }
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
        let screenIndex = screens.index(for: frame)
        let screen = screens[screenIndex]
        let tiled = order.compactMap { windows[$0] }.filter { w in
            w.workspace == window.workspace && !w.isFloating && bounds[w.id] != nil
        }
        guard let position = tiled.firstIndex(where: { $0.id == window.id }), tiled.count > 1 else { return }
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
                resize(window, among: Array(tiled.dropFirst()), by: delta, length: splitIsHorizontal ? area.height : area.width)
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

    /// Changes the window's weight so it gains `delta` points, the others sharing the difference.
    private func resize(_ window: ManagedWindow, among group: [ManagedWindow], by delta: CGFloat, length: CGFloat) {
        guard let index = group.firstIndex(where: { $0 === window }) else { return }
        window.weight = Self.weight(at: index, of: group.map(\.weight), growingBy: delta, length: length, gap: config.gap)
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
        if window.isFloating { AX.focus(window.element, pid: window.pid) }
        scheduleRetile()
    }

    /// Moves the focused window into the workspace shown on the next display.
    func moveToNextDisplay() {
        let screens = ScreenInfo.current()
        guard screens.count > 1, let window = focused(), let frame = onScreenBounds()[window.id] else { return }
        syncDisplays()
        let next = screens[(screens.index(for: frame) + 1) % screens.count]
        if let workspace = displayed[next.id] { window.workspace = workspace }
        if window.isFloating || !running {
            let size = CGSize(width: min(frame.width, next.visible.width), height: min(frame.height, next.visible.height))
            setFrame(window, CGRect(x: next.visible.midX - size.width / 2, y: next.visible.midY - size.height / 2,
                                    width: size.width, height: size.height))
        }
        retile()
        followFocusAfter = Date().addingTimeInterval(0.6)
        AX.focus(window.element, pid: window.pid)
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
            let isMaster = order.first { other in
                guard let w = windows[other], w.workspace == window.workspace, !w.isFloating, let f = bounds[other] else { return false }
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
