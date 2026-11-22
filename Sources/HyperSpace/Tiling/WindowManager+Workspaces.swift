import AppKit

/// Workspaces: switching to one, moving a window to one, and what the menu bar and the menu show of them.
extension WindowManager {
    // MARK: - Workspaces

    /// Shows a workspace on its own display and focuses it; the other displays keep theirs.
    func switchWorkspace(_ index: Int) {
        scoped {
            guard running, (0..<workspaceCount).contains(index) else { return }
            syncDisplays()
            let screens = currentScreens()
            guard let screen = home(of: index, screens) else { return }
            // Even with nothing to focus (an empty workspace), the refocusing caused by hiding
            // the old windows must not bring the old workspace back.
            ignoreFocusChanges()
            let focusedWorkspace = self.focusedWorkspace
            log.debug("switch to workspace \(index) on display \(screen.id) (shown there: \(self.displayed[screen.id] ?? -1), focused: \(focusedWorkspace ?? -1))")
            if let current = focusedWorkspace, current != index {
                previousWorkspace = current
                if let window = focused(), isMember(window, of: current) { focusState.lastFocused[current] = window.id }
            }
            // Any workspace switch closes the scratchpad, the one you are on included: left on
            // screen behind the windows focused below, it would still show (in gaps, screenshots).
            let shown = windows.values.filter { $0.scratchpad && $0.scratchpadShown }
            if !shown.isEmpty { parkScratchpad(shown, screens: screens, bounds: currentBounds()) }
            if displayed[screen.id] != index {
                showWorkspace(index, on: screen.id)
                retile()
            }
            // The focus moves asynchronously: the menu bar is told what it will be, not what the
            // old window still is (an empty workspace has no focus change to correct it later).
            let target = focusWindow(in: index)
            // A real switch takes the pointer to the middle of the display (pointer follows focus);
            // not while a button is held, which would end a drag.
            if focusedWorkspace != index, config.mouseFollowsFocus, NSEvent.pressedMouseButtons == 0 {
                Pointer.warp(to: screen.visible.center)
            }
            notifyWorkspace(focused: .some(target))
        }
    }

    func switchToPreviousWorkspace() {
        if let previousWorkspace { switchWorkspace(previousWorkspace) }
    }

    /// Moves only the focused window; the displays keep showing what they show.
    func moveFocusedWindow(toWorkspace index: Int) {
        scoped {
            guard running, (0..<workspaceCount).contains(index), let focusedWindow = focused() else { return }
            // A dialog shares its window's workspace: its window moves, and the dialog with it.
            let parent = scratchpadOwner(of: focusedWindow) == nil ? focusedWindow.parent.flatMap { windows[$0] } : nil
            let window = parent ?? focusedWindow
            guard window.workspace != index else { return }
            let source = window.workspace
            ignoreFocusChanges()
            // Its dialogs go along.
            let moving = setWorkspace(index, of: window)
            log.debug("move window \(window.id) (\(window.appLabel, privacy: .public)) from workspace \(source) to \(index), shown: \(self.display(showing: index) != nil)")
            // A floating window going to a workspace shown on another display keeps its place there.
            carryFloating(moving, screens: currentScreens())
            retile()
            if let shownOn = display(showing: index) {
                // Still in view and focused, on the display showing that workspace: no focus
                // change tells, so it is noted here (an accordion there brings it to the front).
                guard isMember(focusedWindow, of: index) else { return }
                focusState.lastFocused[index] = focusedWindow.id
                focusState.activeDisplay = shownOn
                if takesTile(focusedWindow), inAccordion(focusedWindow, layout: state(for: shownOn).layout) {
                    columns[index]?.setFront(focusedWindow.id)
                    scheduleRetile()
                }
                return
            }
            // It went out of sight: focus what is left, and if nothing is, keep its workspace hidden.
            focusState.movedAway = focusedWindow.id
            focusWindow(in: source)
        }
    }

    /// Tells the menu bar what each display shows; called often (every focus change), so it
    /// only looks up the focused display when there are several, and only reports changes.
    func notifyWorkspace(focused window: ManagedWindow?? = nil) {
        scoped {
            var notice: WorkspaceBar?
            if running, config.enabled, config.workspaces.count > 1 {
                let screens = currentScreens()
                let names = screens.map { displayed[$0.id].map(name(of:)) ?? "–" }
                let focusedID = screens.count > 1 ? focusedScreen(window ?? focused())?.id : nil
                notice = WorkspaceBar(names: names, focused: screens.firstIndex { $0.id == focusedID } ?? 0)
            }
            if let last = lastNotice, last == notice { return }
            lastNotice = .some(notice)
            onWorkspaceChange?(notice)
        }
    }

    // MARK: - Menu

    /// Every workspace with its windows in tiling order, for when the menu opens. Titles are
    /// the ones kept up to date by the title notifications: no AX round trip here. Only reads:
    /// which workspace each display shows is kept current by the display changes themselves.
    func summaries() -> [WorkspaceSummary] {
        scopedValue {
            guard running, config.enabled, config.workspaces.count > 1 else { return [] }
            let screens = currentScreens()
            var owners: [pid_t: NSRunningApplication] = [:]
            // In tiling order within each workspace; the scratchpad and its dialogs are in none.
            let byWorkspace = Dictionary(grouping: orderedWindows.filter { isMember($0, of: $0.workspace) }, by: \.workspace)
            return (0..<workspaceCount).map { index in
                let members = byWorkspace[index] ?? []
                let entries = members.map { window -> WorkspaceSummary.Window in
                    let app = owners[window.pid] ?? NSRunningApplication(processIdentifier: window.pid)
                    owners[window.pid] = app
                    let title = window.title?.nilIfEmpty
                    return WorkspaceSummary.Window(app: app?.localizedName ?? window.bundleID ?? "App",
                                                   title: title, icon: app?.icon)
                }
                let display = display(showing: index).flatMap { id in screens.firstIndex { $0.id == id } }.map { $0 + 1 }
                return WorkspaceSummary(index: index, name: name(of: index), display: display, windows: entries)
            }
        }
    }
}
