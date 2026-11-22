import AppKit

/// Focus: which window has it (as the apps report it), giving it to a window or to an empty
/// display, and following it to the workspace of the window the user focuses.
extension WindowManager {
    /// The window commands act on: the focused one, except while the focus is held on an
    /// empty display (`focusState.heldDisplay`) and macOS still reports the window left behind
    /// on another display as focused. That window is not where you are: nil then.
    func focused() -> ManagedWindow? {
        guard let window = reportedFocused() else { return nil }
        guard let held = focusState.heldDisplay else { return window }
        guard let frame = currentBounds()[window.id], currentScreens().screen(for: frame)?.id == held else { return nil }
        return window
    }

    /// The focused window as macOS reports it (see `readFocused`), even while the focus is held
    /// on an empty display: to tell when the user focuses a window again.
    func reportedFocused() -> ManagedWindow? {
        if let scope, scope.focusedRead { return scope.focused }
        let window = readFocused()
        if scope != nil {
            scope?.focusedRead = true
            scope?.focused = window
        }
        return window
    }

    /// The frontmost app's focused window, as its notifications reported it: no AX round trip,
    /// so a busy or hung app cannot hold up a shortcut. It is checked again right after, off
    /// the main thread, for apps that do not always announce a focus change. Only an app not
    /// looked at yet is asked here, once.
    private func readFocused() -> ManagedWindow? {
        guard let pid = frontmostPID,
              let watcher = apps[pid] else { return nil }
        if let id = focusState.focusedIn[pid] {
            refreshFocused(pid)
            return windows[id]
        }
        let id = AX.focusedWindowID(of: watcher.element)
        focusState.focusedIn[pid] = id ?? 0
        return id.flatMap { windows[$0] }
    }

    /// Records the focused window of an app (nil: none, or one not known yet).
    func noteFocused(_ id: CGWindowID?, of pid: pid_t) {
        focusState.focusedIn[pid] = id ?? 0
        focusState.focusEpoch[pid, default: 0] += 1
    }

    /// Asks the app for its focused window on its AX queue; a change (that no newer
    /// notification already reported) is recorded and followed like a notification.
    func refreshFocused(_ pid: pid_t) {
        guard let app = apps[pid]?.element else { return }
        let epoch = focusState.focusEpoch[pid, default: 0]
        axQueues.read(pid, { AX.focusedWindowID(of: app) }, then: { [weak self] (id: CGWindowID?) in
            guard let self, apps[pid] != nil, focusState.focusEpoch[pid, default: 0] == epoch, focusState.focusedIn[pid] != id ?? 0 else { return }
            noteFocused(id, of: pid)
            scheduleFocusUpdate()
        })
    }

    /// The workspace shown on the display the user works on.
    var focusedWorkspace: Int? { focusedScreen().flatMap { displayed[$0.id] } }

    /// The display the user works on: the focused window's, else the one we last moved the
    /// focus to (an empty workspace has no window), else the one under the pointer.
    func focusedScreen(_ focusedWindow: ManagedWindow?? = nil) -> ScreenInfo? {
        let screens = currentScreens()
        guard !screens.isEmpty else { return nil }
        // On an empty workspace the window left behind may still look focused.
        if let id = focusState.heldDisplay, let screen = screens.first(id: id) { return screen }
        if let window = focusedWindow ?? focused(), window.hiddenFrame == nil, display(showing: window.workspace) != nil,
           let screen = screen(of: window, at: currentBounds()[window.id], screens) {
            return screen
        }
        if let id = focusState.activeDisplay, let screen = screens.first(id: id) { return screen }
        let pointer = Pointer.location
        return screens.first { $0.frame.contains(pointer) } ?? screens.first
    }

    /// The display a window is on. For a tiled window of a workspace in view that is the
    /// display showing the workspace, wherever the window still is (its parking corner, the
    /// display its workspace just left: our moves are on their way, and what a command read
    /// before them is old); for the others the display of `frame`.
    func screen(of window: ManagedWindow, at frame: CGRect?, _ screens: [ScreenInfo]) -> ScreenInfo? {
        if takesTile(window), let id = display(showing: window.workspace), let screen = screens.first(id: id) { return screen }
        return frame.flatMap { screens.screen(for: $0) }
    }

    /// An app activation and its focused-window change arrive together: one lookup for both.
    func scheduleFocusUpdate() {
        guard running else { return }
        focusCoalescer.schedule { [weak self] in self?.updateFocus() }
    }

    private func updateFocus() {
        scoped {
            // As macOS reports it: focusing the window left behind is how you leave an empty display.
            let window = reportedFocused()
            if let window, window.pid != focusState.frontPID {
                // Its app came to the front (⌘Tab, a click, the Dock): its dialogs come along.
                let dialogs = dialogs(of: window)
                if !dialogs.isEmpty { axQueues.perform(window.pid) { dialogs.forEach(AX.raise) } }
            }
            focusState.frontPID = window?.pid ?? frontmostPID
            followFocus(window)
            notifyWorkspace(focused: window)
        }
    }

    /// Focus changes in the next moment come from us (hiding windows makes apps refocus),
    /// not from the user, and must not switch workspaces.
    func ignoreFocusChanges() {
        focusState.followAfter = Date().addingTimeInterval(Delay.focusIgnore)
    }

    /// Focuses a window without the resulting focus change switching workspaces. Crossing
    /// to another display brings the pointer along (if enabled), and as macOS sometimes
    /// ignores a background app raising a window on another display, it checks and retries.
    /// `frame` is where the window is going, when we just moved it (the move is not done yet).
    func focus(_ window: ManagedWindow, at frame: CGRect? = nil) {
        scoped {
            ignoreFocusChanges()
            focusState.request += 1
            let request = focusState.request
            releaseHeldFocus()
            let dialogs = dialogs(of: window)
            axQueues.perform(window.pid) {
                AX.focus(window.element, pid: window.pid)
                dialogs.forEach(AX.raise)
            }
            focusState.frontPID = window.pid
            let frame = frame ?? currentBounds()[window.id]
            if let screen = screen(of: window, at: frame, currentScreens()) {
                focusState.activeDisplay = screen.id
                // Its frame may still be the one it is leaving (a parking corner, another
                // display): then the middle of the display it is going to.
                let center = frame.map(\.center).flatMap { screen.frame.contains($0) ? $0 : nil }
                bringPointer(to: center ?? screen.visible.center, on: screen)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Delay.focusRetry) { [weak self] in
                // A later focus (another workspace, keys pressed in a row) wins over this retry.
                guard let self, focusState.request == request, windows[window.id] === window,
                      frontmostPID != window.pid else { return }
                note("focus did not take for \(window.appLabel) window \(window.id), retrying")
                ignoreFocusChanges()
                NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateAllWindows])
                axQueues.perform(window.pid) { AX.focus(window.element, pid: window.pid) }
            }
        }
    }

    /// The dialogs of a window that are on screen: they come to the front with it.
    private func dialogs(of window: ManagedWindow) -> [AXUIElement] {
        let shown = Set(displayed.values)
        return dialogWindows(of: window).filter { $0.hiddenFrame == nil && belongsOnScreen($0, shown: shown) }.map(\.element)
    }

    /// Moves the pointer to `point` when it is on another display than `screen`.
    func bringPointer(to point: CGPoint, on screen: ScreenInfo) {
        guard config.mouseFollowsFocus, !screen.frame.contains(Pointer.location) else { return }
        Pointer.warp(to: point)
    }

    /// Focuses the workspace: its last focused window, or with no windows, its display.
    /// Returns the window it focuses (nil for the display alone).
    @discardableResult
    func focusWindow(in workspace: Int) -> ManagedWindow? {
        scopedValue {
            let bounds = currentBounds()
            let candidates = orderedWindows.filter { isMember($0, of: workspace) && bounds[$0.id] != nil }
            if let target = candidates.first(where: { $0.id == focusState.lastFocused[workspace] }) ?? candidates.first {
                focus(target)
                return target
            } else if let id = display(showing: workspace), case let screens = currentScreens(),
                      let screen = screens.first(id: id) {
                focusState.activeDisplay = id
                // Already holding the focus there (the same workspace asked again, a held key
                // repeating): nothing to do, the pointer is not clicked again.
                if focusState.heldDisplay == id, focusAnchor.shown { return nil }
                bringPointer(to: screen.visible.center, on: screen)
                // Nothing to focus there: take the keyboard away from the window you left (on
                // another display it would keep typing there). The desktop of that display is
                // clicked, which makes the Finder active there: macOS then makes it the active
                // display too (menu bar, new windows, Spotlight open there).
                // The window left behind may report focus again meanwhile: that is not the user
                // leaving the empty display (as in `switchWorkspace`).
                ignoreFocusChanges()
                focusState.request += 1
                focusState.heldDisplay = id
                focusAnchor.show(on: screen)
            }
            return nil
        }
    }

    /// Focuses a workspace (see `focusWindow`) and tells the menu bar where the focus is going:
    /// it moves asynchronously, and an empty workspace has no focus change to tell later.
    func focusWorkspace(_ workspace: Int) {
        let window = focusWindow(in: workspace)
        notifyWorkspace(focused: .some(window))
    }

    /// The focus leaves the empty workspace it was held on.
    func releaseHeldFocus() {
        focusState.heldDisplay = nil
        focusAnchor.dismiss()
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    func followFocus(_ window: ManagedWindow?) {
        guard running else { return }
        guard let window else {
            // Another app with no window of ours (⌘Tab to one, Spotlight): the empty display is
            // left too. The Finder is the app our click made active there.
            if focusState.heldDisplay != nil, Date() > focusState.followAfter,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" { releaseHeldFocus() }
            return
        }
        // A window focused by the user (not the refocusing we cause): the empty display is left.
        if focusState.heldDisplay != nil, Date() > focusState.followAfter { releaseHeldFocus() }
        window.focusedAt = Date()
        // A dialog of a scratchpad window lives with it, not in a workspace.
        if let owner = scratchpadOwner(of: window) {
            owner.focusedAt = window.focusedAt
            return
        }
        if window.scratchpad {
            // ⌘Tab or the Dock to a hidden scratchpad window: show it instead of a workspace.
            if !window.scratchpadShown, Date() > focusState.followAfter { showScratchpad(window) }
            return
        }
        if window.hiddenFrame == nil, let id = display(showing: window.workspace) {
            focusState.activeDisplay = id
            if focusState.lastFocused[window.workspace] != window.id {
                focusState.lastFocused[window.workspace] = window.id
                // An accordion brings the focused window to the front, in the middle.
                if !window.isFloating, inAccordion(window, layout: state(for: id).layout) {
                    columns[window.workspace]?.setFront(window.id)
                    scheduleRetile()
                }
            }
        }
        if window.id != focusState.movedAway { focusState.movedAway = nil }
        guard Date() > focusState.followAfter, window.id != focusState.movedAway, display(showing: window.workspace) == nil else { return }
        log.debug("follow focus to window \(window.id) (\(window.appLabel, privacy: .public)) in workspace \(window.workspace)")
        switchWorkspace(window.workspace)
    }
}
