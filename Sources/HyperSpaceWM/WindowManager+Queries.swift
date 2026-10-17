import AppKit
import HyperSpaceCore

extension WindowManager {
    // MARK: - Queries

    public struct MenuWindow: Sendable {
        public let id: WindowID
        public let pid: pid_t
        public let app: String
        public let title: String
    }

    /// Every workspace with windows, plus the shown ones, in display order, with its windows
    /// in tree order then floating: what the menu lists.
    public var workspaceWindows: [(name: String, focused: Bool, windows: [MenuWindow])] {
        guard let model else { return [] }
        let focused = model.focusedWorkspace.name
        return model.workspaceNames.compactMap { name in
            let ids = model.workspaces[name]?.windows ?? []
            guard !ids.isEmpty || model.isVisible(name) else { return nil }
            let windows = ids.compactMap { id in
                records[id].map { MenuWindow(id: id, pid: $0.app.pid, app: $0.app.name, title: $0.record.title) }
            }
            return (name, name == focused, windows)
        }
    }

    /// `%{name}` variables of AeroSpace's `--format`, `test` and `echo`.
    func variables(window: WindowID?, workspace name: String? = nil) -> [String: String] {
        guard let model else { return [:] }
        var values: [String: String] = [:]
        // A window set aside (minimized, in macOS full screen, its app hidden) is listed with
        // the workspace it comes back to, which may be gone meanwhile.
        let aside = window.flatMap { model.windows[$0] == nil ? setAside[$0] : nil }
        let workspaceName = name ?? aside?.spot.workspace ?? window.flatMap { model.workspace(of: $0)?.name } ?? model.focusedWorkspace.name
        let workspace = model.workspaces[workspaceName]
        values["workspace"] = workspaceName
        values["workspace-is-focused"] = String(workspaceName == model.focusedWorkspace.name)
        values["workspace-is-visible"] = String(model.isVisible(workspaceName))
        let monitorID = model.visible.first { $0.value == workspaceName }?.key ?? model.assignedMonitor(workspaceName)
        if let index = model.monitors.firstIndex(where: { $0.id == monitorID }) {
            values["monitor-id"] = String(index + 1)
            values["monitor-name"] = model.monitors[index].name
        }
        if let window, let (app, record) = records[window] {
            values["window-id"] = String(window)
            values["window-title"] = record.title
            values["window-is-fullscreen"] = String(workspace?.fullscreen == window || aside?.spot.fullscreen == true)
            values["window-layout"] = (model.windows[window]?.floating ?? aside?.spot.floating) == true ? "floating" : "tiling"
            // HyperSpace's own: on a Space of its own, out of the layout.
            values["window-is-macos-fullscreen"] = String(nativeFullscreen.contains(window))
            // HyperSpace's own: a shown scratchpad, and the workspace it goes back to.
            let home = model.scratchpadHomes[window]
            values["window-is-scratchpad"] = String(home != nil)
            values["window-scratchpad-home"] = home?.workspace ?? ""
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
                let ids = monitorIDs(monitors)
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
                ids = names.flatMap { name in windows(of: name == "focused" ? model.focusedWorkspace.name : name) }
            } else if let monitors = filters["--monitor"] {
                let monitorIDs = monitorIDs(monitors)
                ids = model.visible.filter { monitorIDs.contains($0.key) }.flatMap { windows(of: $0.value) }
            } else {
                let names = model.workspaceNames
                ids = names.flatMap(windows(of:)) + asideWindows.filter { !names.contains($0.workspace) }.map(\.id)
            }
            if let pid = filters["--pid"]?.first.flatMap(Int32.init) { ids = ids.filter { records[$0]?.app.pid == pid } }
            if let bundle = filters["--app-bundle-id"]?.first { ids = ids.filter { records[$0]?.app.bundleID == bundle } }
            return format(ids.map { variables(window: $0) }, query, default: "%{window-id} | %{app-name} | %{window-title}")
        case .monitors:
            // `--all`: the displays left out too (no monitor id: the model doesn't have them).
            var monitors = filters["--all"] != nil ? system.monitors() : model.monitors
            if filters["--focused"] != nil { monitors = monitors.filter { $0.id == model.focusedMonitor } }
            let rows = monitors.map { monitor in
                ["monitor-id": model.monitors.firstIndex { $0.id == monitor.id }.map { String($0 + 1) } ?? "",
                 "monitor-name": monitor.name,
                 "monitor-is-ignored": String(isIgnored(monitor.key)),
                 "monitor-input": monitorInputs[monitor.key].map { String(format: "0x%02x", $0) } ?? ""]
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

    /// The workspace's windows, then the ones set aside that come back to it.
    private func windows(of name: String) -> [WindowID] {
        (model?.workspaces[name]?.windows ?? []) + asideWindows.filter { $0.workspace == name }.map(\.id)
    }

    /// Windows set aside, by id, with the workspace each comes back to.
    private var asideWindows: [(id: WindowID, workspace: String)] {
        setAside.filter { records[$0.key] != nil && model?.windows[$0.key] == nil }
            .map { ($0.key, $0.value.spot.workspace) }.sorted { $0.id < $1.id }
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

    /// `--monitor` values, as in AeroSpace: `all`, `focused`, `mouse`, or a monitor pattern.
    private func monitorIDs(_ patterns: [String]) -> Set<UInt32> {
        guard let model else { return [] }
        return Set(patterns.flatMap { pattern -> [UInt32] in
            switch pattern {
            case "all":
                return model.monitors.map(\.id)
            case "focused":
                return [model.focusedMonitor]
            case "mouse":
                let mouse = CGEvent(source: nil)?.location ?? .zero
                return model.monitors.filter { $0.frame.contains(mouse) }.map(\.id)
            default:
                return model.monitors.first { WMMonitor.matches(pattern, $0, in: model.monitors) }.map { [$0.id] } ?? []
            }
        })
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
