import AppKit

/// Displays: the display each workspace lives on, which workspace each display shows, what
/// happens when displays come and go, and the layout of each display.
extension WindowManager {
    /// The display a workspace lives on: the one it is pinned to in the config, else where it
    /// was moved, otherwise workspace n on the n-th display and the rest on the main one
    /// (displays in `ScreenInfo.current()` order). A pin to a display not connected is ignored
    /// until that display is back.
    func home(of workspace: Int, _ screens: [ScreenInfo]) -> ScreenInfo? {
        homeID(of: workspace, screens).flatMap { screens.first(id: $0) }
    }

    private func homeID(of workspace: Int, _ screens: [ScreenInfo]) -> CGDirectDisplayID? {
        Self.homeDisplay(of: workspace, movedTo: movedTo(workspace, screens), displays: screens.map(\.id))
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

    static func homeIndex(of workspace: Int, displays: Int) -> Int {
        workspace < displays ? workspace : 0
    }

    /// Shows a workspace on a display, remembering what it replaces.
    func showWorkspace(_ workspace: Int?, on display: CGDirectDisplayID) {
        if let current = displayed[display], current != workspace { shownBefore[display] = current }
        displayed[display] = workspace
    }

    func display(showing workspace: Int) -> CGDirectDisplayID? {
        displayed.first { $0.value == workspace }?.key
    }

    /// Every display shows one of its own workspaces (the lowest numbered by default), or
    /// none when no workspace lives there.
    /// A display that went away remembers what it showed (by UUID), and shows it again when
    /// it comes back, so a monitor plugged in again finds its workspace and windows as they were.
    func syncDisplays() {
        let screens = currentScreens()
        let ids = screens.map(\.id)
        let count = workspaceCount
        // The empty display the focus was held on is gone: nothing is held any more.
        if let held = focusState.heldDisplay, !ids.contains(held) { releaseHeldFocus() }
        // Looked up while connected: a display gone may have no UUID to ask for any more.
        for screen in screens { _ = screen.uuid }
        for (display, workspace) in displayed where !ids.contains(display) {
            departed[ScreenInfo.uuid(of: display)] = workspace
        }
        let home = { [self] (workspace: Int) in homeID(of: workspace, screens) }
        for screen in screens where displayed[screen.id] == nil {
            guard let workspace = departed.removeValue(forKey: screen.uuid), workspace < count,
                  home(workspace) == screen.id else { continue }
            log.debug("display \(screen.id) is back: shows workspace \(workspace) again")
            for (display, shown) in displayed where shown == workspace { displayed[display] = nil }
            displayed[screen.id] = workspace
        }
        displayed = Self.syncedDisplays(displayed, displays: ids, workspaces: count, home: home)
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

    func displaysChanged() {
        // The focused window of the removed display moving must not switch workspaces.
        ignoreFocusChanges()
        screensRead = nil
        syncDisplays()
        // At least one workspace per display: one fewer display can mean one fewer workspace.
        let count = workspaceCount
        if displayed.values.contains(where: { $0 >= count }) || windows.values.contains(where: { $0.workspace >= count }) {
            fitWorkspaces(to: count)
            syncDisplays()
        }
        // macOS relocates the windows of the removed display a moment after the notification.
        scheduleRetile(after: Delay.displayChangeSettle)
        notifyWorkspace()
    }

    /// Fewer workspaces than before (a reload, or a display unplugged with fewer workspaces
    /// configured than displays): what belonged to the removed ones is forgotten, and their
    /// windows join the first workspace.
    func fitWorkspaces(to count: Int) {
        displayed = displayed.filter { $0.value < count }
        homeOverride = homeOverride.filter { $0.key < count }
        accordionWorkspaces = accordionWorkspaces.filter { $0 < count }
        shownBefore = shownBefore.filter { $0.value < count }
        if let previous = previousWorkspace, previous >= count { previousWorkspace = nil }
        let fitted = Self.fittedWorkspaces(windows.mapValues(\.workspace), count: count)
        for (id, workspace) in fitted { windows[id]?.workspace = workspace }
        columns = columns.filter { $0.key < count }
        focusState.lastFocused = focusState.lastFocused.filter { $0.key < count }
    }

    /// Each window's workspace once there are only `count`: those of removed workspaces join the first.
    static func fittedWorkspaces(_ workspaces: [CGWindowID: Int], count: Int) -> [CGWindowID: Int] {
        workspaces.mapValues { $0 < count ? $0 : 0 }
    }

    func state(for screen: CGDirectDisplayID?) -> ScreenState {
        screen.flatMap { screenStates[ScreenInfo.uuid(of: $0)] } ?? ScreenState(layout: config.layout, ratio: config.masterRatio)
    }

    func setState(_ state: ScreenState, for screen: CGDirectDisplayID) {
        screenStates[ScreenInfo.uuid(of: screen)] = state
    }

    func updateActiveScreen(_ change: (inout ScreenState) -> Void) {
        scoped {
            guard running, let id = focusedScreen()?.id else { return }
            var state = state(for: id)
            change(&state)
            setState(state, for: id)
            scheduleRetile()
        }
    }
}
