import CoreGraphics

/// A display, in AX coordinates (origin at the top left of the main display, y down).
public struct WMMonitor: Sendable, Equatable {
    public let id: UInt32
    /// The whole display.
    public var frame: CGRect
    /// Without the menu bar and the Dock: where windows go.
    public var visible: CGRect

    public init(id: UInt32, frame: CGRect, visible: CGRect) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

public struct WMWindowInfo: Sendable, Equatable {
    public let id: WindowID
    public let pid: Int32
    public let bundleID: String?
    /// Floating windows keep their own frame; the others are tiled.
    public var floating: Bool

    public init(id: WindowID, pid: Int32, bundleID: String?, floating: Bool) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.floating = floating
    }
}

/// A virtual workspace: a tiling tree plus floating windows. Workspaces are not macOS
/// Spaces: one is shown per monitor, the windows of the others wait off-screen.
public final class WMWorkspace {
    public let name: String
    public let root = WMNode(orientation: .horizontal)
    public internal(set) var floating: [WindowID] = []
    /// A tiled window shown over the whole workspace.
    public internal(set) var fullscreen: WindowID?
    /// The monitor the workspace was last shown on.
    public internal(set) var monitor: UInt32?

    init(name: String) { self.name = name }

    public var windows: [WindowID] { root.windows + floating }
    public var isEmpty: Bool { root.children.isEmpty && floating.isEmpty }
}

/// What applying the model to the screen means: computed by `WMModel.layout()` and turned
/// into AX calls by the window manager service, which only touches what changed.
public struct WMLayout: Sendable, Equatable {
    /// Tiled windows of visible workspaces and their frames.
    public var tiled: [WindowID: CGRect] = [:]
    /// Floating windows of visible workspaces: they keep (or get back) their own frame.
    public var floating: [WindowID: UInt32] = [:]
    /// Windows of hidden workspaces, with the monitor whose corner hides them.
    public var hidden: [WindowID: UInt32] = [:]
}

/// What a command asks the service to do besides layout.
public enum WMEffect: Sendable, Equatable {
    case none
    case close(WindowID)
    case exec(String)
    case reloadConfig
    case enable(Bool?)
}

/// The window manager's state and every command, as pure logic over ids and rectangles.
/// The service feeds it AX events (windows appearing, focus changes, monitors) and applies
/// `layout()` back; nothing here talks to other processes, so it's fast and testable.
public final class WMModel {
    public var settings: WMSettings
    public private(set) var monitors: [WMMonitor] = []
    public private(set) var workspaces: [String: WMWorkspace] = [:]
    /// Monitor id -> name of the workspace it shows.
    public private(set) var visible: [UInt32: String] = [:]
    public private(set) var focusedMonitor: UInt32 = 0
    public private(set) var focused: WindowID?
    public private(set) var windows: [WindowID: WMWindowInfo] = [:]
    private var previousWorkspace: String?
    /// Recently focused windows, most recent last: where focus goes when a window leaves.
    private var history: [WindowID] = []

    public init(monitors: [WMMonitor], settings: WMSettings = WMSettings()) {
        self.settings = settings
        setMonitors(monitors)
    }

    public var focusedWorkspace: WMWorkspace { workspace(visible[focusedMonitor] ?? "1") }

    public func workspace(_ name: String) -> WMWorkspace {
        if let workspace = workspaces[name] { return workspace }
        let workspace = WMWorkspace(name: name)
        workspaces[name] = workspace
        return workspace
    }

    public func workspace(of window: WindowID) -> WMWorkspace? {
        workspaces.values.first { $0.floating.contains(window) || $0.root.find(window) != nil }
    }

    /// Workspace names in display order: numbers first, by value, then the others.
    public var workspaceNames: [String] {
        workspaces.keys.sorted { a, b in
            switch (Int(a), Int(b)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a < b
            }
        }
    }

    // MARK: - Events from the system

    /// Displays changed. Each monitor keeps its workspace if it had one; new monitors get
    /// the first free workspace; workspaces of removed monitors become hidden.
    public func setMonitors(_ monitors: [WMMonitor]) {
        self.monitors = monitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let ids = Set(monitors.map(\.id))
        visible = visible.filter { ids.contains($0.key) }
        for monitor in self.monitors where visible[monitor.id] == nil {
            let name = (1...).lazy.map(String.init).first { name in
                !self.visible.values.contains(name) && (self.workspaces[name]?.isEmpty ?? true)
            }!
            visible[monitor.id] = name
            workspace(name).monitor = monitor.id
        }
        if !ids.contains(focusedMonitor) { focusedMonitor = self.monitors.first?.id ?? 0 }
    }

    /// A new window. It joins the workspace a rule names, else the one shown on `monitor`
    /// (where it appeared), else the focused one; tiled windows go next to the focused window.
    public func add(_ info: WMWindowInfo, monitor: UInt32? = nil) {
        guard windows[info.id] == nil else { return }
        var info = info
        let rule = settings.rule(for: info.bundleID)
        if rule?.floating == true { info.floating = true }
        windows[info.id] = info
        let target = rule?.workspace.map { workspace($0) }
            ?? monitor.flatMap { visible[$0] }.map { workspace($0) }
            ?? focusedWorkspace
        if info.floating {
            target.floating.append(info.id)
        } else {
            insertTiled(info.id, into: target)
        }
    }

    public func remove(_ window: WindowID) {
        guard windows.removeValue(forKey: window) != nil, let workspace = workspace(of: window) else { return }
        detach(window, from: workspace)
        history.removeAll { $0 == window }
        if focused == window { focused = recent(in: workspace) }
        collectEmptyWorkspaces()
    }

    /// macOS focused a window (click, ⌘-Tab, an app opening one). If it sits on a hidden
    /// workspace, that workspace is shown, as in AeroSpace.
    @discardableResult
    public func nativeFocus(_ window: WindowID?) -> Bool {
        guard let window, let workspace = workspace(of: window) else { return false }
        let before = visible
        if let monitor = visible.first(where: { $0.value == workspace.name })?.key {
            focusedMonitor = monitor
        } else {
            show(workspace.name, on: focusedMonitor)
        }
        focus(window)
        return before != visible
    }

    // MARK: - Commands

    /// Runs a command. Returns what else the service must do; errors are user mistakes
    /// worth reporting (`hsctl`), not failures.
    public func run(_ command: WMCommand) throws(InvalidConfig) -> WMEffect {
        switch command {
        case let .focus(direction):
            guard let node = focusedNode, let target = neighbor(of: node, direction) else { return .none }
            focus(target)
        case let .move(direction):
            guard let node = focusedNode else { throw InvalidConfig(message: "no tiled window is focused") }
            move(node, direction)
        case let .joinWith(direction):
            guard let node = focusedNode else { throw InvalidConfig(message: "no tiled window is focused") }
            join(node, direction)
        case let .resize(target, amount):
            guard let node = focusedNode else { throw InvalidConfig(message: "no tiled window is focused") }
            resize(node, target, amount)
        case .balanceSizes:
            balance(focusedWorkspace.root)
        case .flattenWorkspaceTree:
            let root = focusedWorkspace.root
            for window in root.windows { if let node = root.find(window) { root.insert(node) } }
            balance(root)
        case let .layout(choices):
            try layout(choices)
        case let .fullscreen(on):
            guard let window = focused, focusedNode != nil else { throw InvalidConfig(message: "no tiled window is focused") }
            let workspace = focusedWorkspace
            workspace.fullscreen = (on ?? (workspace.fullscreen != window)) ? window : nil
        case let .workspace(target):
            switchTo(try name(of: target))
        case .workspaceBackAndForth:
            if let previous = previousWorkspace { switchTo(previous) }
        case let .moveNodeToWorkspace(target, follows):
            guard let window = focused else { throw InvalidConfig(message: "no window is focused") }
            moveWindow(window, to: try name(of: target), follow: follows)
        case let .focusMonitor(target):
            guard let monitor = monitor(target) else { return .none }
            focusedMonitor = monitor
            focusRecent(in: focusedWorkspace)
        case let .moveNodeToMonitor(target):
            guard let window = focused, let monitor = monitor(target), let name = visible[monitor] else { return .none }
            moveWindow(window, to: name, follow: true)
        case let .moveWorkspaceToMonitor(target):
            guard let monitor = monitor(target), let other = visible[monitor] else { return .none }
            let current = focusedWorkspace.name
            visible[monitor] = current
            visible[focusedMonitor] = other
            workspace(current).monitor = monitor
            workspace(other).monitor = focusedMonitor
            focusedMonitor = monitor
        case .close:
            guard let window = focused else { throw InvalidConfig(message: "no window is focused") }
            return .close(window)
        case let .exec(command):
            return .exec(command)
        case .reloadConfig:
            return .reloadConfig
        case let .enable(on):
            return .enable(on)
        }
        focusedWorkspace.root.normalize()
        return .none
    }

    // MARK: - Layout

    /// Frames for every window of the visible workspaces, plus where the others hide.
    public func layout() -> WMLayout {
        var result = WMLayout()
        for monitor in monitors {
            guard let name = visible[monitor.id], let workspace = workspaces[name] else { continue }
            let outer = settings.outerGap
            let rect = monitor.visible.insetBy(dx: outer, dy: outer)
            frames(workspace.root, rect, into: &result.tiled)
            if let fullscreen = workspace.fullscreen, result.tiled[fullscreen] != nil { result.tiled[fullscreen] = rect.pixelAligned }
            for window in workspace.floating { result.floating[window] = monitor.id }
        }
        for (name, workspace) in workspaces where !visible.values.contains(name) {
            let monitor = workspace.monitor.flatMap { id in monitors.first { $0.id == id }?.id } ?? monitors.first?.id ?? 0
            for window in workspace.windows { result.hidden[window] = monitor }
        }
        return result
    }

    private func frames(_ node: WMNode, _ rect: CGRect, into result: inout [WindowID: CGRect]) {
        if let window = node.window {
            result[window] = rect.pixelAligned
            return
        }
        let count = node.children.count
        guard count > 0 else { return }
        let horizontal = node.orientation == .horizontal
        switch node.layout {
        case .tiles:
            let gap = settings.innerGap
            let length = (horizontal ? rect.width : rect.height) - gap * Double(count - 1)
            node.lastLength = length
            let total = node.children.reduce(0) { $0 + $1.weight }
            var offset = horizontal ? rect.minX : rect.minY
            for child in node.children {
                let size = length * child.weight / total
                let childRect = horizontal
                    ? CGRect(x: offset, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: size)
                frames(child, childRect, into: &result)
                offset += size + gap
            }
        case .accordion:
            // Every child gets nearly the whole rect, shifted so the others peek out by the
            // padding on each side of the most recent one.
            let padding = settings.accordionPadding
            let recent = node.recent.flatMap { $0.index } ?? 0
            for (i, child) in node.children.enumerated() {
                let (before, after): (Double, Double) = switch i {
                case 0 where count == 1: (0, 0)
                case 0: (0, padding)
                case count - 1: (padding, 0)
                case recent - 1: (0, 2 * padding)
                case recent + 1: (2 * padding, 0)
                default: (padding, padding)
                }
                let childRect = horizontal
                    ? CGRect(x: rect.minX + before, y: rect.minY, width: rect.width - before - after, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + before, width: rect.width, height: rect.height - before - after)
                frames(child, childRect, into: &result)
            }
        }
    }

    // MARK: - Private: focus and workspaces

    /// The focused window's tree node, if it's tiled on the focused workspace.
    private var focusedNode: WMNode? {
        focused.flatMap { focusedWorkspace.root.find($0) }
    }

    private func focus(_ window: WindowID) {
        focused = window
        workspace(of: window)?.root.find(window)?.markRecent()
        history.removeAll { $0 == window }
        history.append(window)
        if history.count > 64 { history.removeFirst() }
    }

    private func focusRecent(in workspace: WMWorkspace) {
        if let window = recent(in: workspace) { focus(window) } else { focused = nil }
    }

    /// The most recently focused window still on `workspace`.
    private func recent(in workspace: WMWorkspace) -> WindowID? {
        let windows = Set(workspace.windows)
        return history.last { windows.contains($0) } ?? workspace.root.recentWindow?.window ?? workspace.floating.last
    }

    private func focus(_ node: WMNode) {
        if let window = node.recentWindow?.window { focus(window) }
    }

    private func name(of target: WMCommand.WorkspaceTarget) throws(InvalidConfig) -> String {
        switch target {
        case let .named(name):
            return name
        case .next, .prev:
            let names = workspaceNames.filter { !workspace($0).isEmpty || $0 == focusedWorkspace.name }
            guard let index = names.firstIndex(of: focusedWorkspace.name), names.count > 1 else { return focusedWorkspace.name }
            return names[(index + (target == .next ? 1 : -1) + names.count) % names.count]
        }
    }

    private func switchTo(_ name: String) {
        guard name != focusedWorkspace.name else { return }
        previousWorkspace = focusedWorkspace.name
        if let monitor = visible.first(where: { $0.value == name })?.key {
            focusedMonitor = monitor // already shown on another monitor: go there
        } else {
            show(name, on: focusedMonitor)
        }
        focusRecent(in: focusedWorkspace)
    }

    private func show(_ name: String, on monitor: UInt32) {
        visible[monitor] = name
        workspace(name).monitor = monitor
        collectEmptyWorkspaces()
    }

    /// Hidden empty workspaces are dropped; they come back when named again.
    private func collectEmptyWorkspaces() {
        for (name, workspace) in workspaces where workspace.isEmpty && !visible.values.contains(name) {
            workspaces[name] = nil
        }
    }

    private func moveWindow(_ window: WindowID, to name: String, follow: Bool) {
        guard let from = workspace(of: window), from.name != name else { return }
        let floating = from.floating.contains(window)
        detach(window, from: from)
        let target = workspace(name)
        if floating { target.floating.append(window) } else { insertTiled(window, into: target) }
        if follow {
            switchTo(name)
            focus(window)
        } else {
            focused = recent(in: from)
        }
    }

    private func detach(_ window: WindowID, from workspace: WMWorkspace) {
        workspace.floating.removeAll { $0 == window }
        workspace.root.find(window)?.removeFromParent()
        if workspace.fullscreen == window { workspace.fullscreen = nil }
        workspace.root.normalize()
    }

    private func insertTiled(_ window: WindowID, into workspace: WMWorkspace) {
        let node = WMNode(window: window)
        if workspace.root.children.isEmpty, let monitor = monitors.first(where: { $0.id == workspace.monitor }) ?? monitors.first {
            workspace.root.orientation = monitor.visible.width >= monitor.visible.height ? .horizontal : .vertical
        }
        if let focused, let anchor = workspace.root.find(focused), let parent = anchor.parent, let index = anchor.index {
            parent.insert(node, at: index + 1)
        } else {
            workspace.root.insert(node)
        }
        workspace.root.normalize()
    }

    private func monitor(_ target: WMCommand.MonitorTarget) -> UInt32? {
        guard let current = monitors.firstIndex(where: { $0.id == focusedMonitor }), monitors.count > 1 else { return nil }
        switch target {
        case .next: return monitors[(current + 1) % monitors.count].id
        case .prev: return monitors[(current - 1 + monitors.count) % monitors.count].id
        case let .direction(direction):
            let from = monitors[current].frame
            let candidates = monitors.filter { monitor in
                switch direction {
                case .left: monitor.frame.maxX <= from.minX
                case .right: monitor.frame.minX >= from.maxX
                case .up: monitor.frame.maxY <= from.minY
                case .down: monitor.frame.minY >= from.maxY
                }
            }
            func distance(_ m: WMMonitor) -> Double { hypot(m.frame.midX - from.midX, m.frame.midY - from.midY) }
            return candidates.min { distance($0) < distance($1) }?.id
        }
    }

    // MARK: - Private: tree commands

    /// The window in `direction` from `node`: up the tree to the first container laid out
    /// along that axis with a sibling there, then down that sibling to the window nearest
    /// to where we came from (or its most recent one across the other axis).
    private func neighbor(of node: WMNode, _ direction: Direction) -> WMNode? {
        var current = node
        while let parent = current.parent {
            if parent.orientation == direction.orientation, let index = current.index,
               parent.children.indices.contains(index + direction.offset) {
                return descend(parent.children[index + direction.offset], direction)
            }
            current = parent
        }
        return nil
    }

    private func descend(_ node: WMNode, _ direction: Direction) -> WMNode {
        guard node.isContainer, !node.children.isEmpty else { return node }
        if node.orientation == direction.orientation {
            return descend(direction.offset > 0 ? node.children.first! : node.children.last!, direction)
        }
        return descend(node.recent ?? node.children.first!, direction)
    }

    /// AeroSpace's `move`: swap with a sibling window, enter a sibling container, or leave
    /// the container in that direction; at the workspace edge the root is wrapped in a new
    /// container along the direction.
    private func move(_ node: WMNode, _ direction: Direction) {
        guard let parent = node.parent, let index = node.index else { return }
        let target = index + direction.offset
        if parent.orientation == direction.orientation, parent.children.indices.contains(target) {
            let sibling = parent.children[target]
            if sibling.isContainer {
                // Into the container: its edge facing us if it runs along the direction,
                // else next to its most recent window.
                let deep = deepTarget(sibling, direction.orientation)
                if deep.isContainer {
                    deep.insert(node, at: direction.offset > 0 ? 0 : deep.children.count)
                } else if let deepParent = deep.parent, let deepIndex = deep.index {
                    deepParent.insert(node, at: deepIndex + 1)
                }
            } else {
                let weight = node.weight
                parent.insert(node, at: target) // swap places
                node.weight = weight
            }
            return
        }
        // Leave: find the closest ancestor whose parent runs along the direction.
        var current = parent
        while let up = current.parent, up.orientation != direction.orientation { current = up }
        if let up = current.parent, let currentIndex = current.index {
            up.insert(node, at: currentIndex + (direction.offset > 0 ? 1 : 0))
            return
        }
        // At the workspace edge: wrap the root's content and put the window beside it.
        let root = current
        guard root.children.count > 1 || root.orientation != direction.orientation else { return }
        let wrapper = WMNode(orientation: root.orientation, layout: root.layout)
        for child in root.children where child !== node {
            let weight = child.weight
            wrapper.insert(child)
            child.weight = weight
        }
        root.orientation = direction.orientation
        root.layout = .tiles
        node.removeFromParent()
        root.insert(wrapper)
        root.insert(node, at: direction.offset > 0 ? 1 : 0)
    }

    private func deepTarget(_ node: WMNode, _ orientation: Orientation) -> WMNode {
        guard node.isContainer, node.orientation != orientation, let next = node.recent ?? node.children.last else { return node }
        return deepTarget(next, orientation)
    }

    /// AeroSpace's `join-with`: the window and its neighbor in `direction` share a new
    /// container laid out across the current one.
    private func join(_ node: WMNode, _ direction: Direction) {
        guard let parent = node.parent, parent.orientation == direction.orientation,
              let index = node.index, parent.children.indices.contains(index + direction.offset) else { return }
        let sibling = parent.children[index + direction.offset]
        let container = WMNode(orientation: parent.orientation.opposite)
        parent.insert(container, at: min(index, index + direction.offset))
        container.weight = node.weight + sibling.weight
        for child in direction.offset > 0 ? [node, sibling] : [sibling, node] { container.insert(child) }
        node.markRecent()
    }

    private func resize(_ node: WMNode, _ target: WMCommand.ResizeTarget, _ amount: WMCommand.ResizeAmount) {
        // The node whose parent runs along the axis being resized.
        var current = node
        while let parent = current.parent {
            let axis: Orientation? = switch target {
            case .smart: nil
            case .width: .horizontal
            case .height: .vertical
            }
            if parent.layout == .tiles, parent.children.count > 1, axis == nil || parent.orientation == axis { break }
            current = parent
        }
        guard let parent = current.parent, parent.lastLength > 0 else { return }
        let others = parent.children.reduce(0) { $0 + ($1 === current ? 0 : $1.weight) }
        let total = others + current.weight
        let pixels = current.weight / total * parent.lastLength
        let wanted = switch amount {
        case let .add(delta): pixels + delta
        case let .set(value): value
        }
        let clamped = min(max(wanted, 50), parent.lastLength - 50 * Double(parent.children.count - 1))
        current.weight = clamped * others / max(parent.lastLength - clamped, 1)
    }

    private func balance(_ node: WMNode) {
        for child in node.children {
            child.weight = 1
            balance(child)
        }
    }

    private func layout(_ choices: [WMCommand.LayoutChoice]) throws(InvalidConfig) {
        guard let window = focused, let workspace = workspace(of: window) else { throw InvalidConfig(message: "no window is focused") }
        let node = workspace.root.find(window)
        let parent = node?.parent
        func isCurrent(_ choice: WMCommand.LayoutChoice) -> Bool {
            switch choice {
            case .floating: return node == nil
            case .tiling: return node != nil
            case .tiles: return parent?.layout == .tiles
            case .accordion: return parent?.layout == .accordion
            case .horizontal: return parent?.orientation == .horizontal
            case .vertical: return parent?.orientation == .vertical
            case .hTiles: return parent?.layout == .tiles && parent?.orientation == .horizontal
            case .vTiles: return parent?.layout == .tiles && parent?.orientation == .vertical
            case .hAccordion: return parent?.layout == .accordion && parent?.orientation == .horizontal
            case .vAccordion: return parent?.layout == .accordion && parent?.orientation == .vertical
            }
        }
        let choice = choices.first { !isCurrent($0) } ?? choices[0]
        switch choice {
        case .floating:
            guard node != nil else { return }
            detach(window, from: workspace)
            workspace.floating.append(window)
            windows[window]?.floating = true
        case .tiling:
            guard node == nil else { return }
            workspace.floating.removeAll { $0 == window }
            windows[window]?.floating = false
            insertTiled(window, into: workspace)
        default:
            guard let parent else { throw InvalidConfig(message: "the focused window is floating") }
            switch choice {
            case .tiles, .hTiles, .vTiles: parent.layout = .tiles
            case .accordion, .hAccordion, .vAccordion: parent.layout = .accordion
            default: break
            }
            switch choice {
            case .horizontal, .hTiles, .hAccordion: parent.orientation = .horizontal
            case .vertical, .vTiles, .vAccordion: parent.orientation = .vertical
            default: break
            }
            // A nested container now running along its parent's axis is merged into it, which
            // is what the new orientation means and keeps containers alternating.
            if let grand = parent.parent, grand.orientation == parent.orientation, let index = parent.index {
                for (offset, child) in parent.children.enumerated() { grand.insert(child, at: index + offset) }
            }
        }
    }
}

extension CGRect {
    /// Edges rounded to whole points, so neighbors share an edge instead of overlapping.
    var pixelAligned: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        return CGRect(x: x0, y: y0, width: maxX.rounded() - x0, height: maxY.rounded() - y0)
    }
}
