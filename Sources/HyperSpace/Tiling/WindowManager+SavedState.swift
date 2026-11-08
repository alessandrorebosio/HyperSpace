import AppKit
import ApplicationServices

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
            if let workspace = Int(key), workspace < workspaceCount { homeOverride[workspace] = uuid }
        }
        for (uuid, workspace) in state.displays ?? [:] where workspace < workspaceCount {
            if let display = byUUID[uuid] { displayed[display] = workspace } else { departed[uuid] = workspace }
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
    func applyRestoredLayout() {
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
            shown[ScreenInfo.uuid(of: display)] = workspace
        }
        state.displays = shown
        state.moved = Dictionary(uniqueKeysWithValues: homeOverride.map { (String($0.key), $0.value) })
        state.layouts = screenStates.mapValues { .init(layout: $0.layout.rawValue, ratio: Double($0.ratio)) }
        return (state, list.map(\.element))
    }

    /// Reads the windows' titles over AX (slow: not on the main thread, which is why the state
    /// is written without them first).
    static func fillTitles(_ state: inout WorkspaceState, _ elements: [AXUIElement]) {
        for i in elements.indices { state.windows[i].title = AX.string(elements[i], kAXTitleAttribute) ?? "" }
    }

    /// Saves a moment after a change, when something really changed. Not while windows are
    /// still being matched to the saved state, which would lose the apps not reopened yet.
    func scheduleSave() {
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
                WindowManager.fillTitles(&state, elements)
                state.savedAt = Date()
                state.save()
            }
        }
    }

    /// Saves at once (on quit), keeping the saved windows not found again yet.
    func saveState() {
        guard running else { return }
        var (state, elements) = currentState()
        WindowManager.fillTitles(&state, elements)
        if let restorer { state.windows += restorer.unclaimed }
        state.savedAt = Date()
        saveQueue.sync {}
        state.save()
    }
}
