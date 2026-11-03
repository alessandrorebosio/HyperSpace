import AppKit
import ApplicationServices

/// Workspaces and displays: which workspace each display shows, switching, moving, focus following, and the menu's summaries.
extension WindowManager {
    // MARK: - Workspaces

    /// The display a workspace lives on: the one it is pinned to in the config, else where it
    /// was moved, otherwise workspace n on the n-th display and the rest on the main one
    /// (displays in `ScreenInfo.current()` order). A pin to a display not connected is ignored
    /// until that display is back.
    func home(of workspace: Int, _ screens: [ScreenInfo]) -> ScreenInfo? {
        let id = Self.homeDisplay(of: workspace, movedTo: movedTo(workspace, screens), displays: screens.map(\.id))
        return screens.first { $0.id == id }
    }

    /// The connected display a workspace is pinned to, if any.
    func pinnedDisplay(of workspace: Int, _ screens: [ScreenInfo]) -> ScreenInfo? {
        config.pins[workspace].flatMap { ScreenInfo.pinned($0, among: screens) }
    }

    /// The connected display a workspace is pinned or was moved to, if any.
    private func movedTo(_ workspace: Int, _ screens: [ScreenInfo]) -> CGDirectDisplayID? {
        pinnedDisplay(of: workspace, screens)?.id
            ?? homeOverride[workspace].flatMap { uuid in screens.first { $0.uuid == uuid }?.id }
    }

    /// `displays` in `ScreenInfo.current()` order; a move to a display no longer there is ignored.
    static func homeDisplay(of workspace: Int, movedTo: CGDirectDisplayID?, displays: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        if let movedTo, displays.contains(movedTo) { return movedTo }
        return displays.isEmpty ? nil : displays[homeIndex(of: workspace, displays: displays.count)]
    }

    /// Shows a workspace on a display, remembering what it replaces.
    func showWorkspace(_ workspace: Int?, on display: CGDirectDisplayID) {
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
    func syncDisplays() {
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

    func display(showing workspace: Int) -> CGDirectDisplayID? {
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
    func hide(_ window: ManagedWindow, from frame: CGRect, screens: [ScreenInfo]) {
        guard window.hiddenFrame == nil, !screens.isEmpty else { return }
        window.hiddenFrame = frame
        let screen = screens[screens.index(for: frame)].frame
        let element = window.element
        writer.perform(window.pid) { AX.setPosition(element, CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)) }
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    func restore(_ window: ManagedWindow, on screen: ScreenInfo, _ screens: [ScreenInfo]) {
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
    func carryFloating(_ members: [ManagedWindow], screens: [ScreenInfo]) {
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
    func focusWindow(in workspace: Int) -> ManagedWindow? {
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
    func releaseHeldFocus() {
        heldDisplay = nil
        focusAnchor.dismiss()
    }

    /// ⌘Tab or a click on a window of a hidden workspace shows that workspace.
    func followFocus(_ window: ManagedWindow?) {
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
    func notifyWorkspace(focused window: ManagedWindow?? = nil) {
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
}
