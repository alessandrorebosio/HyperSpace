import AppKit
import HyperSpaceCore

extension WindowManager {
    // MARK: - Queries

    /// `%{name}` variables of AeroSpace's `--format`, `test` and `echo`.
    func variables(window: WindowID?, workspace name: String? = nil) -> [String: String] {
        guard let model else { return [:] }
        var values: [String: String] = [:]
        let workspace = name.map { model.workspace($0) } ?? window.flatMap { model.workspace(of: $0) } ?? model.focusedWorkspace
        values["workspace"] = workspace.name
        values["workspace-is-focused"] = String(workspace.name == model.focusedWorkspace.name)
        values["workspace-is-visible"] = String(model.isVisible(workspace.name))
        let monitorID = model.visible.first { $0.value == workspace.name }?.key ?? model.assignedMonitor(workspace.name)
        if let index = model.monitors.firstIndex(where: { $0.id == monitorID }) {
            values["monitor-id"] = String(index + 1)
            values["monitor-name"] = model.monitors[index].name
        }
        if let window, let (app, record) = records[window] {
            values["window-id"] = String(window)
            values["window-title"] = record.title
            values["window-is-fullscreen"] = String(workspace.fullscreen == window)
            values["window-layout"] = model.windows[window]?.floating == true ? "floating" : "tiling"
            values["app-name"] = app.name
            values["app-bundle-id"] = app.bundleID ?? ""
            values["app-pid"] = String(app.pid)
        }
        return values
    }

    func interpolate(_ text: String, window: WindowID?) -> String {
        guard text.contains("%{") else { return text }
        let values = variables(window: window)
        return text.replacing(/%\{([a-z-]+)\}/) { values[String($0.1)] ?? "" }
    }

    func list(_ query: WMCommand.ListQuery) -> String {
        guard let model else { return "" }
        let filters = query.filters
        switch query.kind {
        case .workspaces:
            var names = model.workspaceNames
            if filters["--focused"] != nil { names = [model.focusedWorkspace.name] }
            if let monitors = filters["--monitor"] {
                let ids = Set(monitors.compactMap { monitorID($0) })
                names = names.filter { model.assignedMonitor($0).map(ids.contains) ?? false }
            }
            if let visible = filters["--visible"] { names = names.filter { model.isVisible($0) != (visible == ["no"]) } }
            if let empty = filters["--empty"] { names = names.filter { (model.workspaces[$0]?.isEmpty ?? true) != (empty == ["no"]) } }
            return format(names.map { variables(window: nil, workspace: $0) }, query, default: "%{workspace}")
        case .windows:
            var ids: [WindowID]
            if filters["--focused"] != nil {
                ids = model.focused.map { [$0] } ?? []
            } else if let names = filters["--workspace"] {
                ids = names.flatMap { name in
                    model.workspaces[name == "focused" ? model.focusedWorkspace.name : name]?.windows ?? []
                }
            } else if let monitors = filters["--monitor"] {
                let monitorIDs = Set(monitors.compactMap { monitorID($0) })
                ids = model.visible.filter { monitorIDs.contains($0.key) }.flatMap { model.workspace($0.value).windows }
            } else {
                ids = model.workspaceNames.flatMap { model.workspaces[$0]?.windows ?? [] }
            }
            if let pid = filters["--pid"]?.first.flatMap(Int32.init) { ids = ids.filter { records[$0]?.app.pid == pid } }
            if let bundle = filters["--app-bundle-id"]?.first { ids = ids.filter { records[$0]?.app.bundleID == bundle } }
            return format(ids.map { variables(window: $0) }, query, default: "%{window-id} | %{app-name} | %{window-title}")
        case .monitors:
            var monitors = model.monitors
            if filters["--focused"] != nil { monitors = monitors.filter { $0.id == model.focusedMonitor } }
            let rows = monitors.map { monitor in
                ["monitor-id": String((model.monitors.firstIndex { $0.id == monitor.id } ?? 0) + 1), "monitor-name": monitor.name]
            }
            return format(rows, query, default: "%{monitor-id} | %{monitor-name}")
        case .apps:
            let rows = system.runningApps().map { app in
                ["app-pid": String(app.pid), "app-bundle-id": app.bundleID ?? "", "app-name": app.name]
            }
            return format(rows, query, default: "%{app-pid} | %{app-bundle-id} | %{app-name}")
        case .modes:
            let modes = filters["--current"] != nil ? [mode] : settings.modes.keys.sorted()
            return format(modes.map { ["mode-id": $0] }, query, default: "%{mode-id}")
        }
    }

    private func format(_ rows: [[String: String]], _ query: WMCommand.ListQuery, default fallback: String) -> String {
        if query.count { return String(rows.count) }
        if query.json {
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }
        let format = query.format ?? fallback
        return rows.map { row in format.replacing(/%\{([a-z-]+)\}/) { row[String($0.1)] ?? "" } }.joined(separator: "\n")
    }

    private func monitorID(_ pattern: String) -> UInt32? {
        guard let model else { return nil }
        if pattern == "focused" { return model.focusedMonitor }
        return model.monitors.first { WMMonitor.matches(pattern, $0, in: model.monitors) }?.id
    }

    // MARK: - Mouse

    /// Warps the pointer to the focused monitor or window ("lazy": only if it's elsewhere).
    func moveMouse(_ position: WMCommand.MousePosition) -> Bool {
        guard let model else { return false }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let rect: CGRect? = switch position {
        case .monitorLazyCenter, .monitorForceCenter: model.monitors.first { $0.id == model.focusedMonitor }?.visible
        case .windowLazyCenter, .windowForceCenter: model.focused.flatMap { targets[$0] ?? frames[$0] }
        }
        guard let rect else { return false }
        let lazy = position == .monitorLazyCenter || position == .windowLazyCenter
        if lazy, rect.contains(mouse) { return false }
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
        return true
    }

    /// `focus-follows-mouse`: the window under the pointer gets focus.
    public func mouseMoved(to point: CGPoint) {
        guard let model, settings.focusFollowsMouse, let before = focusState else { return }
        // Called on every pointer move: frames from the last apply, no layout computed.
        let under = lastLayout.floating.keys.first { frames[$0]?.contains(point) == true }
            ?? lastLayout.tiled.first { $0.value.contains(point) }?.key
        guard let under, under != model.focused else { return }
        model.nativeFocus(under)
        focusNative()
        focusChanged(since: before)
    }
}
