import AppKit

/// The workspaces saved across restarts, and how windows found again are matched to them.
extension WindowManager {
    // MARK: - Saved state

    /// Brings back which workspace each display showed and where workspaces were moved;
    /// windows are matched as they are found, for a minute.
    func loadSavedState() {
        guard let state = WorkspaceState.load() else { return }
        let screens = currentScreens()
        let byUUID = Dictionary(screens.map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        // Displays by UUID: any display the monitor was plugged into.
        for (key, uuid) in state.moved ?? [:] {
            // (A pin in the config replaces a move made by hand, a saved one included.)
            if let workspace = Int(key), workspace < workspaceCount, config.pins[workspace] == nil { homeOverride[workspace] = uuid }
        }
        for (uuid, workspace) in state.displays ?? [:] where workspace < workspaceCount {
            if let display = byUUID[uuid] { displayed[display] = workspace } else { departed[uuid] = workspace }
        }
        accordionWorkspaces = Set((state.accordionWorkspaces ?? []).filter { $0 < workspaceCount })
        for (uuid, saved) in state.layouts ?? [:] {
            if let kind = LayoutKind(rawValue: saved.layout) { screenStates[uuid] = ScreenState(layout: kind, ratio: CGFloat(saved.ratio)) }
        }
        restoreSession.state = state
        // Apps that have been running for a while (HyperSpace restarted, not the Mac) may open
        // new windows meanwhile: those do not take a saved window of their app by default.
        let now = Date()
        let established = NSWorkspace.shared.runningApplications.filter { app in
            app.isFinishedLaunching && (app.launchDate.map { now.timeIntervalSince($0) > 30 } ?? true)
        }
        restoreSession.restorer = WorkspaceRestorer(state, windowsAtStart: discovery.windowsAtStart,
                                     appsAtStart: Set(established.map(\.processIdentifier)))
        log.debug("restoring \(state.windows.count) window(s) saved \(state.savedAt, privacy: .public)")
        restoreSession.generation += 1
        let generation = restoreSession.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Delay.restoreWindow) { [weak self] in
            guard let self, restoreSession.generation == generation else { return }
            restoreSession.restorer = nil
            restoreSession.state = nil
            restoreSession.index = [:]
            restoreSession.applied = []
            scheduleSave()
        }
    }

    /// Restored windows take their saved order and columns, each once: a later look for
    /// windows (a Space change) applies only the windows found since, so what you arranged
    /// meanwhile is kept.
    func applyRestoredLayout() {
        guard let state = restoreSession.state else { return }
        let fresh = Set(restoreSession.index.keys.filter { windows[$0] != nil && !restoreSession.applied.contains($0) })
        guard !fresh.isEmpty else { return }
        order = Self.restoredOrder(order, savedIndex: restoreSession.index, placing: fresh)
        let idByIndex = Dictionary(restoreSession.index.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for (key, saved) in state.columns {
            guard let workspace = Int(key) else { continue }
            let arrangement = saved.map { $0.compactMap { idByIndex[$0] } }
            let ids = Set(arrangement.joined())
            guard !ids.isDisjoint(with: fresh) else { continue }
            if ids.isDisjoint(with: restoreSession.applied) {
                // The first windows of this workspace found again: its saved arrangement.
                columns[workspace] = ColumnLayout(columns: arrangement, accordions: Set(state.accordions?[key] ?? []))
            } else {
                // An app reopening later: its windows go back to their places among what is there.
                var layout = columns[workspace] ?? ColumnLayout()
                for id in arrangement.joined() where fresh.contains(id) { layout.insert(id, saved: arrangement) }
                columns[workspace] = layout
            }
        }
        restoreSession.applied.formUnion(fresh)
    }

    /// `order` with the `fresh` restored windows moved to their saved places: before the first
    /// restored window saved after them, else after the last restored one, else first.
    /// (With every restored window fresh: restored ones first, in saved order, then the rest.)
    static func restoredOrder(_ order: [CGWindowID], savedIndex: [CGWindowID: Int], placing fresh: Set<CGWindowID>) -> [CGWindowID] {
        var result = order.filter { !fresh.contains($0) }
        for id in fresh.sorted(by: { savedIndex[$0, default: .max] < savedIndex[$1, default: .max] }) {
            let index = savedIndex[id, default: .max]
            let position = result.firstIndex { savedIndex[$0].map { $0 > index } ?? false }
                ?? result.lastIndex { savedIndex[$0] != nil }.map { $0 + 1 }
                ?? 0
            result.insert(id, at: position)
        }
        return result
    }

    /// The state to save. Titles are the cached ones (kept up to date by the title
    /// notifications): no AX round trip, on the main thread or off it.
    private func currentState() -> WorkspaceState {
        var index: [CGWindowID: Int] = [:]
        var state = WorkspaceState(savedAt: .distantPast)
        for window in orderedWindows {
            guard let app = window.bundleID else { continue }
            index[window.id] = state.windows.count
            state.windows.append(.init(app: app, title: window.title ?? "", workspace: window.workspace,
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
            shown[ScreenInfo.uuid(of: display)] = workspace
        }
        state.displays = shown
        state.moved = Dictionary(uniqueKeysWithValues: homeOverride.map { (String($0.key), $0.value) })
        state.layouts = screenStates.mapValues { .init(layout: $0.layout.rawValue, ratio: Double($0.ratio)) }
        return state
    }

    /// Saves a moment after a change, when something besides titles really changed. Not while
    /// windows are still being matched to the saved state, which would lose the apps not
    /// reopened yet.
    func scheduleSave() {
        guard running, restoreSession.restorer == nil else { return }
        saveCoalescer.schedule { [weak self] in
            guard let self, running, restoreSession.restorer == nil else { return }
            // An app does not always say a window closed: it would stay in the columns, the
            // menu and the file until the next Space change.
            if forgetClosedWindows() { scheduleRetile() }
            var state = currentState()
            guard state.withoutTitles != lastSaved?.withoutTitles else { return }
            lastSaved = state
            state.savedAt = Date()
            saveQueue.async { state.save() }
        }
    }

    /// `state` with the saved windows no window was found for (`unclaimed`, indices into
    /// `saved.windows`) added after its own, in their saved workspaces and columns: each of
    /// their columns after the columns the workspace has now.
    static func keepingUnclaimed(_ unclaimed: [Int], of saved: WorkspaceState, in state: WorkspaceState) -> WorkspaceState {
        var state = state
        var moved: [Int: Int] = [:]
        for index in unclaimed where saved.windows.indices.contains(index) {
            moved[index] = state.windows.count
            state.windows.append(saved.windows[index])
        }
        for (workspace, columns) in saved.columns {
            let kept = columns.map { $0.compactMap { moved[$0] } }.filter { !$0.isEmpty }
            if !kept.isEmpty { state.columns[workspace, default: []] += kept }
        }
        return state
    }

    /// Saves at once (on quit), keeping the saved windows not found again yet.
    func saveState() {
        guard running else { return }
        var state = currentState()
        if let unclaimed = restoreSession.restorer?.unclaimedIndices, let saved = restoreSession.state {
            state = Self.keepingUnclaimed(unclaimed, of: saved, in: state)
        }
        state.savedAt = Date()
        saveQueue.sync {}
        state.save()
    }
}
