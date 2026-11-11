import AppKit

/// Tracking: the apps watched over AX, their windows found and followed (created, closed,
/// moved, refocused, retitled), and where each new window goes.
extension WindowManager {
    func addApp(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard running, app.activationPolicy == .regular, pid != getpid(), apps[pid] == nil, !app.isTerminated else { return }
        if let watcher = AppWatcher(app: app, refcon: refcon) {
            apps[pid] = watcher
            log.debug("watch \(watcher.appLabel, privacy: .public)")
            discover(watcher)
        } else if attempt < 20 {
            if attempt == 0 || attempt == 19 { note("cannot watch \(app.bundleIdentifier ?? "?") yet (attempt \(attempt + 1))") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.addApp(app, attempt: attempt + 1)
            }
        }
    }

    func removeApp(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.invalidate()
        axQueues.forget(pid)
        focusedIn[pid] = nil
        focusEpoch[pid] = nil
        for id in windowIDs[pid] ?? [] { untrack(id) }
        scheduleRetile()
    }

    /// Looks for windows not tracked yet. The app is asked on its own AX queue (a slow app
    /// does not hold up the others or the shortcuts); new windows are tracked on the main
    /// thread and retiled.
    func discover(_ watcher: AppWatcher, then done: (() -> Void)? = nil) {
        let pid = watcher.pid
        let app = watcher.element
        // Windows already tracked are not described again (`track` would skip them anyway):
        // only their id is read, which spares a busy app most of the round trips.
        let known = Set(windowIDs[pid] ?? [])
        pendingDiscoveries += 1
        axQueues.read(pid, {
            let main = AX.element(app, kAXMainWindowAttribute).flatMap(AX.windowID)
            let focused = AX.element(app, kAXFocusedWindowAttribute).flatMap(AX.windowID)
            let unknown = AX.elements(app, kAXWindowsAttribute).filter { element in
                AX.windowID(element).map { !known.contains($0) } ?? true
            }
            return (unknown.map { AX.probe($0, pid: pid, main: .some(main)) }, focused)
        }, then: { [weak self] (probes: [AX.WindowProbe], focused: CGWindowID?) in
            self?.discovered(probes, focused: focused, watcher: watcher, then: done)
        })
    }

    private func discovered(_ probes: [AX.WindowProbe], focused: CGWindowID?, watcher: AppWatcher, then done: (() -> Void)?) {
        let pid = watcher.pid
        scoped {
            var found = false
            if running, apps[pid] === watcher {
                // Known from here on (a notification since then knows better).
                if focusedIn[pid] == nil { focusedIn[pid] = focused ?? 0 }
                for probe in probes where track(probe, in: watcher) != nil { found = true }
            }
            if found { scheduleRetile() }
            done?()
            discoveryFinished()
        }
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
    func whenDiscovered(_ block: @escaping () -> Void) {
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
        let appID = watcher.appLabel
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
        window.title = probe.title
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
           frontmostPID == watcher.pid,
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
        log.debug("track \(watcher.appLabel, privacy: .public) window \(id) workspace \(window.workspace) floating \(window.isFloating)\(parent.map { " dialog of \($0.id)" } ?? "")")
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
            log.debug("reveal workspace \(window.workspace) for opened app \(window.appLabel, privacy: .public)")
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
    func rescan() {
        // (CGWindowListCreate, which returns only the ids, is not available from Swift.)
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
            if let window = managed(element, pid: pid) {
                noteFocused(window.id, of: pid)
            } else {
                // A window not tracked yet: none until its id comes back from the app's queue.
                noteFocused(nil, of: pid)
                refreshFocused(pid)
            }
            scheduleFocusUpdate()
        case kAXTitleChangedNotification:
            // Read on the app's AX queue: a slow app must not hold up the main thread. Many
            // windows set their title a moment after opening: title rules apply then.
            guard let window = managed(element, pid: pid) else { return }
            axQueues.read(pid, { AX.string(element, kAXTitleAttribute) }, then: { [weak self] title in
                guard let self, windows[window.id] === window else { return }
                window.title = title
                guard !config.floatingWindows.isEmpty, !window.userOverride else { return }
                let floats = shouldFloat(window) { title }
                guard floats != window.isFloating else { return }
                window.isFloating = floats
                scheduleRetile()
            })
        default:
            scheduleRetile()
        }
    }

    /// A new window: described on its app's AX queue, then tracked. A window AX does not
    /// describe yet (no subrole) is looked at again a few times.
    private func windowCreated(_ element: AXUIElement, pid: pid_t, attempt: Int = 0) {
        axQueues.read(pid, { AX.probe(element, pid: pid) }, then: { [weak self] probe in
            self?.described(element, probe, pid: pid, attempt: attempt)
        })
    }

    private func described(_ element: AXUIElement, _ probe: AX.WindowProbe, pid: pid_t, attempt: Int) {
        guard running, let watcher = apps[pid] else { return }
        scoped {
            if probe.kind == .pending, attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(1 << attempt)) { [weak self] in
                    self?.windowCreated(element, pid: pid, attempt: attempt + 1)
                }
                return
            }
            guard let window = track(probe, in: watcher) else { return }
            windowTracked(window, watcher: watcher)
        }
    }

    private func windowTracked(_ window: ManagedWindow, watcher: AppWatcher) {
        scoped {
            let pid = watcher.pid
            // A scratchpad window is shown where you are, whatever its workspace.
            if window.scratchpad { return }
            if display(showing: window.workspace) == nil, frontmostPID == pid {
                lastFocused[window.workspace] = window.id
                if watcher.bundleID.flatMap({ config.assignments[$0] }) != nil {
                    // An app you just opened shows its assigned workspace, so its window is visible.
                    switchWorkspace(window.workspace)
                } else {
                    // It finished loading after you left its workspace: it stays there, and
                    // the focus stays where you are.
                    log.debug("window \(window.id) (\(watcher.appLabel, privacy: .public)) opened in hidden workspace \(window.workspace)")
                    let here = activeDisplay.flatMap { displayed[$0] }
                    ignoreFocusChanges()
                    movedAway = window.id
                    retile()
                    if let here { focusWindow(in: here) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.scheduleRetile() }
                }
                return
            }
            // Some apps put the window on screen a moment after announcing it.
            scheduleRetile(after: [0.25])
        }
    }

    /// The tracked window of an AX element, compared locally (asking the app for the
    /// window id would be a round trip, and a destroyed element has none left).
    private func managed(_ element: AXUIElement, pid: pid_t) -> ManagedWindow? {
        for id in windowIDs[pid] ?? [] {
            if let window = windows[id], CFEqual(window.element, element) { return window }
        }
        return nil
    }
}
