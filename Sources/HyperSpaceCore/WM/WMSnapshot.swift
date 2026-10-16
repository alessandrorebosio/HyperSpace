import Foundation

/// The layout saved across restarts: every workspace's tree, its floating windows and the
/// workspaces shown per monitor. Windows keep their id while their app runs, so after a
/// HyperSpace restart they're found by id; after their app restarts, by app and title.
/// Monitors are saved by name: display ids can change across sleep and reboots.
public struct WMSnapshot: Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable {
        public var app: String?
        public var title: String

        public init(app: String?, title: String) {
            self.app = app
            self.title = title
        }
    }

    public indirect enum Node: Codable, Sendable, Equatable {
        case window(WindowID, weight: Double)
        case container(horizontal: Bool, accordion: Bool, weight: Double, children: [Node])
    }

    public struct Workspace: Codable, Sendable, Equatable {
        public var name: String
        public var monitor: String?
        public var root: Node
        public var floating: [WindowID]
        public var fullscreen: WindowID?
    }

    public var workspaces: [Workspace]
    /// Monitor name -> workspace shown there.
    public var visible: [String: String]
    public var focusedWorkspace: String
    public var windows: [WindowID: Identity]
    /// Scratchpad windows, and where the shown ones go back to (absent from older layouts).
    public var scratchpads: [WindowID]?
    public var scratchpadHomes: [WindowID: WMScratchpadHome]?

    /// Saved window -> the window it is now, among `current`: the same id of the same app,
    /// else a window of that app with that title (each used once).
    public func match(_ current: [WindowID: Identity]) -> [WindowID: WindowID] {
        var result: [WindowID: WindowID] = [:]
        var free = current
        for (id, identity) in windows where current[id]?.app == identity.app {
            result[id] = id
            free[id] = nil
        }
        for (id, identity) in windows.sorted(by: { $0.key < $1.key }) where result[id] == nil {
            guard let found = free.filter({ $0.value == identity }).keys.min() else { continue }
            result[id] = found
            free[found] = nil
        }
        return result
    }
}

extension WMModel {
    /// The current layout, with `identity` naming each window for a later `restore`.
    public func snapshot(identity: (WindowID) -> WMSnapshot.Identity) -> WMSnapshot {
        func save(_ node: WMNode) -> WMSnapshot.Node {
            if let window = node.window { return .window(window, weight: node.weight) }
            return .container(horizontal: node.orientation == .horizontal, accordion: node.layout == .accordion,
                              weight: node.weight, children: node.children.map(save))
        }
        let saved = workspaces.values.filter { !$0.isEmpty }.sorted { WMModel.order($0.name, $1.name) }
        return WMSnapshot(
            workspaces: saved.map { workspace in
                WMSnapshot.Workspace(name: workspace.name, monitor: monitors.first { $0.id == workspace.monitor }?.name,
                                     root: save(workspace.root), floating: workspace.floating, fullscreen: workspace.fullscreen)
            },
            visible: Dictionary(visible.compactMap { id, name in monitors.first { $0.id == id }.map { ($0.name, name) } },
                                uniquingKeysWith: { first, _ in first }),
            focusedWorkspace: focusedWorkspace.name,
            windows: Dictionary(uniqueKeysWithValues: windows.keys.map { ($0, identity($0)) }),
            scratchpads: scratchpads.sorted(), scratchpadHomes: scratchpadHomes)
    }

    /// Puts the windows `map` finds (saved id -> current id) back where the snapshot had
    /// them. Windows it doesn't know stay where they are, after the restored ones.
    public func restore(_ snapshot: WMSnapshot, map: [WindowID: WindowID]) {
        func current(_ saved: WindowID) -> WindowID? { map[saved].flatMap { windows[$0] != nil ? $0 : nil } }
        // First take every restored window out of where it was added.
        for saved in snapshot.workspaces {
            for id in saved.floating.compactMap(current) + saved.root.windows.compactMap(current) {
                if let workspace = workspace(of: id) { detach(id, from: workspace) }
            }
        }
        for saved in snapshot.workspaces {
            let workspace = workspace(saved.name)
            if let name = saved.monitor, let monitor = monitors.first(where: { $0.name == name }) { workspace.monitor = monitor.id }
            if case let .container(horizontal, accordion, _, _) = saved.root {
                let root = workspace.root, others = root.children
                for child in others { child.removeFromParent() }
                root.orientation = horizontal ? .horizontal : .vertical
                root.layout = accordion ? .accordion : .tiles
                for child in saved.root.children { build(child, into: root, current) }
                for child in others { root.insert(child) }
                root.normalize()
            }
            for id in saved.floating.compactMap(current) { attachFloating(id, to: workspace) }
            for id in workspace.windows {
                windows[id]?.floating = workspace.floating.contains(id)
                location[id] = workspace.name
            }
            workspace.fullscreen = saved.fullscreen.flatMap(current)
        }
        for (monitorName, name) in snapshot.visible {
            guard let monitor = monitors.first(where: { $0.name == monitorName }), assignedMonitor(name) == monitor.id,
                  !isVisible(name) else { continue }
            visible[monitor.id] = name
            workspace(name).monitor = monitor.id
        }
        for id in (snapshot.scratchpads ?? []).compactMap(current) { scratchpads.insert(id) }
        for (saved, home) in snapshot.scratchpadHomes ?? [:] {
            if let id = current(saved), scratchpads.contains(id) { scratchpadHomes[id] = home }
        }
        if let monitor = visible.first(where: { $0.value == snapshot.focusedWorkspace })?.key { focusedMonitor = monitor }
        if let window = recent(in: focusedWorkspace) { focus(window) }
        collectEmptyWorkspaces()
    }

    private func build(_ saved: WMSnapshot.Node, into parent: WMNode, _ current: (WindowID) -> WindowID?) {
        switch saved {
        case let .window(id, weight):
            guard let id = current(id) else { return }
            let node = WMNode(window: id)
            parent.insert(node)
            node.weight = weight
        case let .container(horizontal, accordion, weight, children):
            let node = WMNode(orientation: horizontal ? .horizontal : .vertical, layout: accordion ? .accordion : .tiles)
            parent.insert(node)
            node.weight = weight
            for child in children { build(child, into: node, current) }
        }
    }
}

extension WMSnapshot.Node {
    var windows: [WindowID] {
        switch self {
        case let .window(id, _): [id]
        case let .container(_, _, _, children): children.flatMap(\.windows)
        }
    }

    var children: [WMSnapshot.Node] {
        if case let .container(_, _, _, children) = self { children } else { [] }
    }
}
