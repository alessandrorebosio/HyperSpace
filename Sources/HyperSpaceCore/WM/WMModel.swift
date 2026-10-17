import CoreGraphics
import Foundation

/// A display, in AX coordinates (origin at the top left of the main display, y down).
public struct WMMonitor: Sendable, Equatable {
    public let id: UInt32
    public var name: String
    /// Which display this is, whatever its id: its EDID UUID, else its name. Two identical
    /// displays have different keys (their serial numbers differ), the same name.
    public var key: String
    /// The "main" display (System Settings > Displays > Use as).
    public var isMain: Bool
    /// The whole display.
    public var frame: CGRect
    /// Without the menu bar and the Dock: where windows go.
    public var visible: CGRect

    public init(id: UInt32, name: String = "", key: String? = nil, isMain: Bool = false, frame: CGRect, visible: CGRect) {
        self.id = id
        self.name = name
        self.key = key ?? name
        self.isMain = isMain
        self.frame = frame
        self.visible = visible
    }
}

/// Where a shown scratchpad came from and goes back to when put away.
public struct WMScratchpadHome: Codable, Sendable, Equatable {
    public var workspace: String
    /// Floating there (a dialog-like window), else tiled.
    public var floating: Bool

    public init(workspace: String, floating: Bool) {
        self.workspace = workspace
        self.floating = floating
    }
}

/// Where a window that leaves the model for a while (minimized, its app hidden) was, to
/// put it back there: its workspace, and next to which sibling window, at which weight.
public struct WMSpot: Codable, Sendable, Equatable {
    public var workspace: String
    public var floating: Bool
    var anchor: WindowID?
    /// After the anchor, else before it.
    var after = true
    var weight = 1.0
    /// Shown over the whole workspace (`fullscreen`), with or without outer gaps.
    var fullscreen = false
    var withoutGaps = false
}

public struct WMWindowInfo: Sendable, Equatable {
    public let id: WindowID
    /// Floating windows keep their own frame; the others are tiled.
    public var floating: Bool

    public init(id: WindowID, floating: Bool) {
        self.id = id
        self.floating = floating
    }
}

/// A virtual workspace: a tiling tree plus floating windows. Workspaces are not macOS
/// Spaces: one is shown per monitor, the windows of the others wait off-screen.
public final class WMWorkspace {
    public let name: String
    public let root: WMNode
    public internal(set) var floating: [WindowID] = []
    /// A tiled window shown over the whole workspace.
    public internal(set) var fullscreen: WindowID?
    var fullscreenWithoutGaps = false
    /// The monitor the workspace belongs to (it was last shown on, or was moved to).
    public internal(set) var monitor: UInt32?

    init(name: String, root: WMNode) {
        self.name = name
        self.root = root
    }

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

    public init() {}
}

/// What a command asks the service to do besides layout.
public enum WMEffect: Sendable, Equatable {
    case none
    case close([WindowID], quitIfLastWindow: Bool)
    case minimize(WindowID)
    case nativeFullscreen(WindowID, Bool?)
}

/// The window manager's state and every tree, workspace and monitor command, as pure logic
/// over ids and rectangles. The service feeds it AX events (windows appearing, focus,
/// monitors), runs the commands that touch other processes itself, and applies `layout()`.
/// Nothing here talks to other processes, so it's fast and testable.
public final class WMModel {
    public var settings: WMSettings
    public private(set) var monitors: [WMMonitor] = []
    public private(set) var workspaces: [String: WMWorkspace] = [:]
    /// Monitor id -> name of the workspace it shows.
    public internal(set) var visible: [UInt32: String] = [:]
    public internal(set) var focusedMonitor: UInt32 = 0
    public private(set) var focused: WindowID?
    public internal(set) var windows: [WindowID: WMWindowInfo] = [:]
    public private(set) var previousWorkspace: String?
    /// Recently focused windows, most recent last.
    private var history: [WindowID] = []
    /// The window a command acts on: `--window-id`, a callback's window, or the focused one.
    private var subject: WindowID?
    /// Window -> name of its workspace, kept by every attach and detach so lookups don't
    /// search every workspace's tree.
    var location: [WindowID: String] = [:]
    /// Display key -> workspace it showed when it was disconnected, to show it again when
    /// the display comes back.
    private var lastShown: [String: String] = [:]
    /// Shown scratchpad windows (`scratchpad`), floating over the focused workspace -> the
    /// workspace they go back to. Put away, they're ordinary windows of it again.
    public internal(set) var scratchpadHomes: [WindowID: WMScratchpadHome] = [:]
    /// Former scratchpads, made ordinary windows by tiling or moving them: the next
    /// `scratchpad` of their app takes another window if it can.
    public private(set) var releasedScratchpads: Set<WindowID> = []

    public init(monitors: [WMMonitor], settings: WMSettings = WMSettings()) {
        self.settings = settings
        setMonitors(monitors)
    }

    public var focusedWorkspace: WMWorkspace { workspace(visible[focusedMonitor] ?? "1") }

    public func workspace(_ name: String) -> WMWorkspace {
        if let workspace = workspaces[name] { return workspace }
        let workspace = WMWorkspace(name: name, root: WMNode(orientation: .horizontal, layout: settings.rootLayout))
        workspaces[name] = workspace
        return workspace
    }

    public func workspace(of window: WindowID) -> WMWorkspace? {
        location[window].flatMap { workspaces[$0] }
    }

    public func isVisible(_ name: String) -> Bool { visible.values.contains(name) }

    /// Workspace names in display order: numbers first, by value, then the others.
    public var workspaceNames: [String] {
        Set(workspaces.keys).union(settings.persistentWorkspaces).sorted(by: WMModel.order)
    }

    static func order(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    // MARK: - Events from the system

    /// Displays changed (connected, disconnected, woken up). Each monitor keeps its
    /// workspace, unless that workspace is forced onto another monitor that is now there.
    /// Monitors without one get, in order: a workspace forced onto them, the one they showed
    /// before they left, one that was last on them, else the first free one. Workspaces of
    /// displays that left stay hidden, on the main monitor, until shown.
    public func setMonitors(_ monitors: [WMMonitor]) {
        let old = self.monitors
        self.monitors = monitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        let ids = Set(monitors.map(\.id))
        // Display ids can change across sleep: a display back under a new id is the same one.
        for monitor in self.monitors where !old.contains(where: { $0.id == monitor.id }) {
            guard let previous = old.first(where: { $0.key == monitor.key && !ids.contains($0.id) }) else { continue }
            if let name = visible.removeValue(forKey: previous.id) { visible[monitor.id] = name }
            for workspace in workspaces.values where workspace.monitor == previous.id { workspace.monitor = monitor.id }
            if focusedMonitor == previous.id { focusedMonitor = monitor.id }
        }
        for (id, name) in visible where !ids.contains(id) {
            if let monitor = old.first(where: { $0.id == id }) { lastShown[monitor.key] = name }
            visible[id] = nil
        }
        for (id, name) in visible where settings.workspaceToMonitor[name] != nil && assignedMonitor(name) != id {
            visible[id] = nil
        }
        for monitor in self.monitors where visible[monitor.id] == nil {
            let remembered = lastShown.removeValue(forKey: monitor.key).flatMap { workspaces[$0] != nil ? [$0] : nil } ?? []
            let name = fallbackWorkspace(for: monitor.id, preferring: remembered)
            visible[monitor.id] = name
            workspace(name).monitor = monitor.id
        }
        if !ids.contains(focusedMonitor) { focusedMonitor = mainMonitor?.id ?? 0 }
        // The focused window left with its display: focus what the focused monitor shows.
        if focused.flatMap({ workspace(of: $0) }).map({ !isVisible($0.name) }) ?? false { focusRecent(in: focusedWorkspace) }
        collectEmptyWorkspaces()
    }

    /// A new window: it joins the workspace shown on `monitor` (where it appeared) or the
    /// focused one, next to the focused window. `on-window-detected` callbacks then run on it.
    public func add(_ info: WMWindowInfo, monitor: UInt32? = nil) {
        guard windows[info.id] == nil else { return }
        windows[info.id] = info
        let target = monitor.flatMap { visible[$0] }.map { workspace($0) } ?? focusedWorkspace
        if info.floating {
            attachFloating(info.id, to: target)
        } else {
            insertTiled(info.id, into: target)
        }
    }

    /// Where `window` is, for `add(_:at:)`. A shown scratchpad's is where it goes back to.
    public func spot(of window: WindowID) -> WMSpot? {
        guard let from = workspace(of: window) else { return nil }
        if let home = scratchpadHomes[window] { return WMSpot(workspace: home.workspace, floating: home.floating) }
        var spot = WMSpot(workspace: from.name, floating: from.floating.contains(window))
        guard let node = from.root.find(window), let siblings = node.parent?.children, let index = node.index else { return spot }
        spot.weight = node.weight
        spot.fullscreen = from.fullscreen == window
        spot.withoutGaps = from.fullscreenWithoutGaps
        if index > 0, let before = siblings[index - 1].window {
            spot.anchor = before
        } else if index + 1 < siblings.count, let next = siblings[index + 1].window {
            spot.anchor = next
            spot.after = false
        }
        return spot
    }

    /// Adds the window back where it was: beside its sibling if that's still there, else in
    /// the same workspace.
    public func add(_ info: WMWindowInfo, at spot: WMSpot) {
        guard windows[info.id] == nil else { return }
        windows[info.id] = WMWindowInfo(id: info.id, floating: spot.floating)
        let target = workspace(spot.workspace)
        if spot.floating {
            attachFloating(info.id, to: target)
        } else if let anchorID = spot.anchor, location[anchorID] == target.name, let anchor = target.root.find(anchorID),
                  let parent = anchor.parent, let index = anchor.index {
            let node = WMNode(window: info.id)
            location[info.id] = target.name
            parent.insert(node, at: spot.after ? index + 1 : index)
            node.weight = spot.weight
            target.root.normalize()
        } else {
            insertTiled(info.id, into: target, nextTo: info.id) // no anchor: at the end
        }
        if spot.fullscreen, !spot.floating, target.fullscreen == nil {
            target.fullscreen = info.id
            target.fullscreenWithoutGaps = spot.withoutGaps
        }
    }

    public func remove(_ window: WindowID) {
        guard windows.removeValue(forKey: window) != nil else { return }
        scratchpadHomes[window] = nil
        releasedScratchpads.remove(window)
        history.removeAll { $0 == window }
        guard let workspace = workspace(of: window) else { return }
        detach(window, from: workspace)
        if focused == window { focused = recent(in: workspace) }
        collectEmptyWorkspaces()
    }

    /// `new` takes `old`'s place everywhere: tree position, workspace, focus history. Used
    /// when the shown tab of a native tab group closes and another tab stands in for it.
    public func replace(_ old: WindowID, with new: WindowID) {
        let workspace = workspace(of: old)
        guard let info = windows[old], workspace != nil else { return }
        windows[old] = nil
        windows[new] = WMWindowInfo(id: new, floating: info.floating)
        if let home = scratchpadHomes.removeValue(forKey: old) { scratchpadHomes[new] = home }
        if releasedScratchpads.remove(old) != nil { releasedScratchpads.insert(new) }
        location[new] = location.removeValue(forKey: old)
        if let workspace {
            if let index = workspace.floating.firstIndex(of: old) { workspace.floating[index] = new }
            workspace.root.find(old)?.window = new
            if workspace.fullscreen == old { workspace.fullscreen = new }
        }
        history = history.map { $0 == old ? new : $0 }
        if focused == old { focused = new }
    }

    /// macOS focused a window (click, ⌘-Tab, an app opening one). If it sits on a hidden
    /// workspace, that workspace is shown, as in AeroSpace. Returns whether visibility changed.
    @discardableResult
    public func nativeFocus(_ window: WindowID?) -> Bool {
        guard let window, let workspace = workspace(of: window) else { return false }
        let before = visible
        show(workspace.name)
        focus(window)
        return before != visible
    }

    /// `scratchpad`: the window is taken from its workspace, its home (or `home`, for a
    /// window just opened for it), and comes floating onto the focused one, focused. Shown
    /// and focused there already, it's put away. Returns whether it's shown now.
    @discardableResult
    public func toggleScratchpad(_ window: WindowID, home: String? = nil) -> Bool {
        guard windows[window] != nil, let from = workspace(of: window) else { return false }
        let target = focusedWorkspace
        defer { collectEmptyWorkspaces() }
        releasedScratchpads.remove(window)
        if scratchpadHomes[window] != nil {
            guard focused == window, from === target else {
                // Shown elsewhere, or not focused: it comes here and gets the focus.
                moveFloating(window, from: from, to: target)
                focus(window)
                return true
            }
            putAway(window)
            return false
        }
        scratchpadHomes[window] = WMScratchpadHome(workspace: home ?? from.name, floating: home == nil && windows[window]?.floating == true)
        windows[window]?.floating = true
        moveFloating(window, from: from, to: target)
        focus(window)
        return true
    }

    /// A shown scratchpad goes back home, an ordinary window again: tiled (or floating, if
    /// it was) next to the window used last there.
    public func putAway(_ window: WindowID) {
        guard let home = scratchpadHomes.removeValue(forKey: window), let from = workspace(of: window) else { return }
        defer { collectEmptyWorkspaces() }
        detach(window, from: from)
        let workspace = workspace(home.workspace)
        windows[window]?.floating = home.floating
        if home.floating {
            attachFloating(window, to: workspace)
        } else {
            insertTiled(window, into: workspace, nextTo: recent(in: workspace))
        }
        if focused == window { focused = recent(in: from) }
    }

    private func moveFloating(_ window: WindowID, from: WMWorkspace, to target: WMWorkspace) {
        detach(window, from: from)
        attachFloating(window, to: target)
    }

    /// The most recently focused of `candidates`, else the lowest id.
    public func mostRecent(of candidates: [WindowID]) -> WindowID? {
        let set = Set(candidates)
        return history.last(where: set.contains) ?? candidates.min()
    }

    // MARK: - Commands

    /// Runs a tree, workspace or monitor command, on `window` if given (`--window-id`, a
    /// callback's window), else on the focused window. Returns whether it succeeded (for
    /// `&&`/`||`) and what else the service must do. Errors are user mistakes worth
    /// reporting, not crashes.
    public func run(_ command: WMCommand, window explicit: WindowID? = nil) throws(InvalidConfig) -> (ok: Bool, effect: WMEffect) {
        // macOS didn't report a focused window we manage (some apps don't answer, or the
        // focus is on a panel): act on the workspace's most recent window, as AeroSpace does.
        if focused.map({ !focusedWorkspace.windows.contains($0) }) ?? true { focusRecent(in: focusedWorkspace) }
        if let explicit, windows[explicit] == nil { throw InvalidConfig(message: "no window with id \(explicit)") }
        subject = explicit ?? focused
        defer {
            for workspace in workspaces.values { workspace.root.normalize() }
            collectEmptyWorkspaces()
        }
        var effect = WMEffect.none
        let ok: Bool
        switch command {
        case let .focus(target, boundaries): ok = try focusCommand(target, boundaries)
        case let .move(direction, boundaries, window: id): ok = try move(id, direction, boundaries)
        case let .swap(target, swapFocus, wrapAround, window: id): ok = try swap(id, target, swapFocus: swapFocus, wrapAround: wrapAround)
        case let .joinWith(direction, window: id): ok = join(try tiledNode(id), direction)
        case let .resize(target, amount, window: id): ok = resize(try tiledNode(id), target, amount)
        case let .balanceSizes(name):
            balance(try workspace(named: name).root)
            ok = true
        case let .flattenWorkspaceTree(name):
            let root = try workspace(named: name).root
            for window in root.windows { if let node = root.find(window) { root.insert(node) } }
            balance(root)
            ok = true
        case let .layout(choices, window: id, workspace: name, root, failIfNoop):
            ok = try layout(choices, window: id, workspace: name, root: root) || !failIfNoop
        case let .fullscreen(on, noOuterGaps, window: id, failIfNoop):
            let node = try tiledNode(id)
            let workspace = workspace(of: node.window!)!
            let wanted = on ?? (workspace.fullscreen != node.window)
            let changed = (workspace.fullscreen == node.window) != wanted
            workspace.fullscreen = wanted ? node.window : nil
            workspace.fullscreenWithoutGaps = noOuterGaps
            ok = changed || !failIfNoop
        case let .macosNativeFullscreen(on, window: id):
            effect = .nativeFullscreen(try window(id), on)
            ok = true
        case let .macosNativeMinimize(window: id):
            effect = .minimize(try window(id))
            ok = true
        case let .workspace(target, autoBackAndForth, wrapAround, failIfNoop):
            guard let name = name(of: target, wrapAround: wrapAround) else { return (!failIfNoop, .none) }
            if autoBackAndForth, name == focusedWorkspace.name, let previous = previousWorkspace {
                ok = switchTo(previous)
            } else {
                ok = switchTo(name) || !failIfNoop
            }
        case .workspaceBackAndForth:
            ok = previousWorkspace.map { switchTo($0) } ?? false
        case let .summonWorkspace(name, failIfNoop):
            guard name != focusedWorkspace.name else { return (!failIfNoop, .none) }
            if let other = visible.first(where: { $0.value == name })?.key {
                visible[other] = focusedWorkspace.name
                workspace(focusedWorkspace.name).monitor = other
            }
            previousWorkspace = focusedWorkspace.name
            visible[focusedMonitor] = name
            workspace(name).monitor = focusedMonitor
            focusRecent(in: workspace(name))
            ok = true
        case let .moveNodeToWorkspace(target, follows, wrapAround, window: id, failIfNoop):
            let window = try window(id)
            guard let name = name(of: target, wrapAround: wrapAround), name != self.workspace(of: window)?.name else {
                return (!failIfNoop, .none)
            }
            moveWindow(window, to: name, follow: follows)
            ok = true
        case let .focusMonitor(target, wrapAround):
            guard let monitor = monitor(target, wrapAround: wrapAround) else { return (false, .none) }
            focusedMonitor = monitor
            focusRecent(in: focusedWorkspace)
            ok = true
        case let .moveNodeToMonitor(target, follows, wrapAround, window: id):
            let window = try window(id)
            guard let monitor = monitor(target, wrapAround: wrapAround), let name = visible[monitor] else { return (false, .none) }
            moveWindow(window, to: name, follow: follows)
            ok = true
        case let .moveWorkspaceToMonitor(target, wrapAround, workspace: name, swap):
            let workspace = try workspace(named: name)
            // Workspaces with a forced assignment stay where they're assigned.
            guard settings.workspaceToMonitor[workspace.name] == nil,
                  let from = visible.first(where: { $0.value == workspace.name })?.key,
                  let monitor = monitor(target, wrapAround: wrapAround, from: from), monitor != from else { return (false, .none) }
            let other = visible[monitor]!
            visible[monitor] = workspace.name
            visible[from] = nil
            workspace.monitor = monitor
            // The workspace it covers comes over in exchange, unless it's assigned to its
            // monitor (or no swap is wanted): then that one waits there, and the monitor
            // left shows one of its own, the one used last there first.
            let replacement = swap && settings.workspaceToMonitor[other] == nil ? other
                : lastUsed(on: from) ?? fallbackWorkspace(for: from)
            visible[from] = replacement
            self.workspace(replacement).monitor = from
            collectEmptyWorkspaces()
            if from == focusedMonitor { focusedMonitor = monitor }
            ok = true
        case .focusBackAndForth:
            guard let previous = history.dropLast().last else { return (false, .none) }
            nativeFocus(previous)
            ok = true
        case let .close(quitIfLastWindow, window: id):
            effect = .close([try window(id)], quitIfLastWindow: quitIfLastWindow)
            ok = true
        case let .closeAllWindowsButCurrent(quitIfLastWindow):
            let current = try window(nil)
            effect = .close(focusedWorkspace.windows.filter { $0 != current }, quitIfLastWindow: quitIfLastWindow)
            ok = true
        default:
            throw InvalidConfig(message: "not a window manager model command")
        }
        return (ok, effect)
    }

    // MARK: - Layout

    /// Frames for every window of the visible workspaces, plus where the others hide.
    public func layout() -> WMLayout {
        var result = WMLayout()
        for monitor in monitors {
            guard let name = visible[monitor.id], let workspace = workspaces[name] else { continue }
            let gaps = settings.resolvedGaps(for: monitor, in: monitors)
            let v = monitor.visible
            let rect = CGRect(x: v.minX + gaps.left, y: v.minY + gaps.top,
                              width: v.width - gaps.left - gaps.right, height: v.height - gaps.top - gaps.bottom)
            frames(workspace.root, rect, gaps: (gaps.horizontal, gaps.vertical), into: &result.tiled)
            if let fullscreen = workspace.fullscreen, result.tiled[fullscreen] != nil {
                result.tiled[fullscreen] = (workspace.fullscreenWithoutGaps ? v : rect).pixelAligned
            }
            for window in workspace.floating { result.floating[window] = monitor.id }
        }
        for (name, workspace) in workspaces where !isVisible(name) {
            let monitor = assignedMonitor(name) ?? monitors.first?.id ?? 0
            for window in workspace.windows { result.hidden[window] = monitor }
        }
        return result
    }

    private func frames(_ node: WMNode, _ rect: CGRect, gaps: (horizontal: Double, vertical: Double),
                        into result: inout [WindowID: CGRect]) {
        if let window = node.window {
            result[window] = rect.pixelAligned
            return
        }
        let count = node.children.count
        guard count > 0 else { return }
        let horizontal = node.orientation == .horizontal
        switch node.layout {
        case .tiles:
            let gap = horizontal ? gaps.horizontal : gaps.vertical
            let length = (horizontal ? rect.width : rect.height) - gap * Double(count - 1)
            node.lastLength = length
            let total = node.children.reduce(0) { $0 + $1.weight }
            var offset = horizontal ? rect.minX : rect.minY
            for child in node.children {
                let size = length * child.weight / total
                let childRect = horizontal
                    ? CGRect(x: offset, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: size)
                frames(child, childRect, gaps: gaps, into: &result)
                offset += size + gap
            }
        case .accordion:
            // AeroSpace's accordion: every child gets nearly the whole rect, shifted so the
            // others peek out by the padding on each side of the most recent one.
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
                frames(child, childRect, gaps: gaps, into: &result)
            }
        }
    }

    // MARK: - Private: subjects

    private func window(_ id: WindowID?) throws(InvalidConfig) -> WindowID {
        guard let window = id ?? subject else { throw InvalidConfig(message: "no window is focused") }
        return window
    }

    private func tiledNode(_ id: WindowID?) throws(InvalidConfig) -> WMNode {
        let window = try window(id)
        guard let node = workspace(of: window)?.root.find(window) else { throw InvalidConfig(message: "the window is floating") }
        return node
    }

    private func workspace(named name: String?) throws(InvalidConfig) -> WMWorkspace {
        guard let name else { return subject.flatMap { workspace(of: $0) } ?? focusedWorkspace }
        guard let workspace = workspaces[name] else { throw InvalidConfig(message: "no workspace named '\(name)'") }
        return workspace
    }

    // MARK: - Private: focus, workspaces, monitors

    func focus(_ window: WindowID) {
        focused = window
        workspace(of: window)?.root.find(window)?.markRecent()
        history.removeAll { $0 == window }
        history.append(window)
        if history.count > 64 { history.removeFirst() }
    }

    private func focus(_ node: WMNode) {
        if let window = node.recentWindow?.window { nativeFocus(window) }
    }

    private func focusRecent(in workspace: WMWorkspace) {
        if let window = recent(in: workspace) { focus(window) } else { focused = nil }
    }

    /// The most recently focused window still on `workspace`.
    func recent(in workspace: WMWorkspace) -> WindowID? {
        let windows = Set(workspace.windows)
        return history.last { windows.contains($0) } ?? workspace.root.recentWindow?.window ?? workspace.floating.last
    }

    private var mainMonitor: WMMonitor? { monitors.first(where: \.isMain) ?? monitors.first }

    /// Where a workspace appears: its forced assignment, else where it was last, else main.
    public func assignedMonitor(_ name: String) -> UInt32? {
        if let patterns = settings.workspaceToMonitor[name] {
            for pattern in patterns {
                if let monitor = monitors.first(where: { WMMonitor.matches(pattern, $0, in: monitors) }) { return monitor.id }
            }
        }
        if let monitor = workspaces[name]?.monitor, monitors.contains(where: { $0.id == monitor }) { return monitor }
        return mainMonitor?.id
    }

    /// Workspaces for next/prev: those of the focused monitor that have windows (or are
    /// persistent, or shown), in display order. Not the scratchpads' fallback workspace.
    private func name(of target: WMCommand.WorkspaceTarget, wrapAround: Bool) -> String? {
        switch target {
        case let .named(name):
            return name
        case .next, .prev:
            let names = workspaceNames.filter { name in
                assignedMonitor(name) == focusedMonitor && name != settings.scratchpadFallbackWorkspace
                    && (!(workspaces[name]?.isEmpty ?? true) || settings.persistentWorkspaces.contains(name) || name == focusedWorkspace.name)
            }
            guard let index = names.firstIndex(of: focusedWorkspace.name) else { return names.first }
            let next = index + (target == .next ? 1 : -1)
            if names.indices.contains(next) { return names[next] }
            return wrapAround ? names[(next + names.count) % names.count] : nil
        }
    }

    @discardableResult
    private func switchTo(_ name: String) -> Bool {
        guard name != focusedWorkspace.name else { return false }
        previousWorkspace = focusedWorkspace.name
        show(name)
        focusRecent(in: focusedWorkspace)
        return true
    }

    /// Shows a workspace on its monitor (AeroSpace: its assigned monitor, main by default)
    /// and focuses that monitor.
    private func show(_ name: String) {
        if let monitor = visible.first(where: { $0.value == name })?.key {
            focusedMonitor = monitor
            return
        }
        let monitor = assignedMonitor(name) ?? focusedMonitor
        visible[monitor] = name
        workspace(name).monitor = monitor
        focusedMonitor = monitor
        collectEmptyWorkspaces()
    }

    /// A workspace for a monitor left without one: one assigned to it, then `preferred`,
    /// then one that lived there, then any other; a new one at worst. Forced ones only on
    /// their monitor; the others not if they live on another one.
    private func fallbackWorkspace(for monitor: UInt32, preferring preferred: [String] = []) -> String {
        let ids = Set(monitors.map(\.id))
        let assigned = settings.workspaceToMonitor.keys.sorted(by: WMModel.order).filter { assignedMonitor($0) == monitor }
        let previous = workspaceNames.filter { workspaces[$0]?.monitor == monitor }
        return (assigned + preferred + previous + workspaceNames).first { name in
            guard !isVisible(name) else { return false }
            if settings.workspaceToMonitor[name] != nil { return assignedMonitor(name) == monitor }
            return workspaces[name]?.monitor.map { $0 == monitor || !ids.contains($0) } ?? true
        }
            ?? (1...).lazy.map(String.init).first { !isVisible($0) && workspaces[$0] == nil }!
    }

    /// The hidden workspace of `monitor` whose window was focused last, if any.
    private func lastUsed(on monitor: UInt32) -> String? {
        history.reversed().lazy.compactMap { self.location[$0] }.first { name in
            !self.isVisible(name) && self.workspaces[name]?.monitor == monitor
                && (self.settings.workspaceToMonitor[name] == nil || self.assignedMonitor(name) == monitor)
        }
    }

    /// Hidden empty workspaces are dropped, unless persistent; they come back when named.
    func collectEmptyWorkspaces() {
        for (name, workspace) in workspaces where workspace.isEmpty && !isVisible(name) && !settings.persistentWorkspaces.contains(name) {
            workspaces[name] = nil
        }
    }

    private func moveWindow(_ window: WindowID, to name: String, follow: Bool) {
        guard let from = workspace(of: window), from.name != name else { return }
        releaseScratchpad(window) // put somewhere on purpose: it stays there
        let floating = from.floating.contains(window)
        detach(window, from: from)
        let target = workspace(name)
        if floating { attachFloating(window, to: target) } else { insertTiled(window, into: target) }
        if follow {
            switchTo(name)
            focus(window)
        } else if focused == window {
            focused = recent(in: from)
        }
    }

    /// A scratchpad tiled or moved by a command becomes an ordinary window, where it is.
    private func releaseScratchpad(_ window: WindowID) {
        if scratchpadHomes.removeValue(forKey: window) != nil { releasedScratchpads.insert(window) }
    }

    func attachFloating(_ window: WindowID, to workspace: WMWorkspace) {
        workspace.floating.append(window)
        location[window] = workspace.name
    }

    func detach(_ window: WindowID, from workspace: WMWorkspace) {
        location[window] = nil
        workspace.floating.removeAll { $0 == window }
        workspace.root.find(window)?.removeFromParent()
        if workspace.fullscreen == window { workspace.fullscreen = nil }
        workspace.root.normalize()
    }

    /// Tiles the window in `workspace`, after `anchor` (default: the focused window) if it's there.
    private func insertTiled(_ window: WindowID, into workspace: WMWorkspace, nextTo anchor: WindowID? = nil) {
        let node = WMNode(window: window)
        location[window] = workspace.name
        if workspace.root.children.isEmpty {
            let monitor = monitors.first { $0.id == assignedMonitor(workspace.name) } ?? mainMonitor
            workspace.root.layout = settings.rootLayout
            workspace.root.orientation = settings.rootOrientation
                ?? ((monitor?.visible.width ?? 1) >= (monitor?.visible.height ?? 0) ? .horizontal : .vertical)
        }
        if let anchorID = anchor ?? focused, anchorID != window, let anchor = workspace.root.find(anchorID),
           let parent = anchor.parent, let index = anchor.index {
            parent.insert(node, at: index + 1)
        } else {
            workspace.root.insert(node)
        }
        workspace.root.normalize()
    }

    /// A monitor by direction (from `from`, default the focused one), next/prev, or pattern.
    private func monitor(_ target: WMCommand.MonitorTarget, wrapAround: Bool, from: UInt32? = nil) -> UInt32? {
        let from = from ?? focusedMonitor
        guard let current = monitors.firstIndex(where: { $0.id == from }) else { return nil }
        switch target {
        case .next, .prev:
            let next = current + (target == .next ? 1 : -1)
            if monitors.indices.contains(next) { return monitors[next].id }
            return wrapAround && monitors.count > 1 ? monitors[(next + monitors.count) % monitors.count].id : nil
        case let .patterns(patterns):
            for pattern in patterns {
                if let monitor = monitors.first(where: { WMMonitor.matches(pattern, $0, in: monitors) }) { return monitor.id }
            }
            return nil
        case let .direction(direction):
            let frame = monitors[current].frame
            func inDirection(_ m: WMMonitor) -> Bool {
                switch direction {
                case .left: m.frame.maxX <= frame.minX
                case .right: m.frame.minX >= frame.maxX
                case .up: m.frame.maxY <= frame.minY
                case .down: m.frame.minY >= frame.maxY
                }
            }
            func distance(_ m: WMMonitor) -> Double { hypot(m.frame.midX - frame.midX, m.frame.midY - frame.midY) }
            if let nearest = monitors.filter(inDirection).min(by: { distance($0) < distance($1) }) { return nearest.id }
            guard wrapAround else { return nil }
            // Wrap: the farthest monitor the other way.
            return monitors.filter { $0.id != from }.max { distance($0) < distance($1) }?.id
        }
    }

    // MARK: - Private: tree commands

    private func focusCommand(_ target: WMCommand.FocusTarget, _ boundaries: WMCommand.Boundaries) throws(InvalidConfig) -> Bool {
        switch target {
        case let .window(id):
            guard windows[id] != nil else { throw InvalidConfig(message: "no window with id \(id)") }
            nativeFocus(id)
            return true
        case let .dfsIndex(index):
            let order = focusedWorkspace.root.windows
            guard order.indices.contains(index) else { return false }
            nativeFocus(order[index])
            return true
        case .dfsNext, .dfsPrev:
            let order = focusedWorkspace.root.windows
            guard let current = subject.flatMap({ order.firstIndex(of: $0) }) else { return false }
            var next = current + (target == .dfsNext ? 1 : -1)
            if !order.indices.contains(next) {
                guard boundaries.action == .wrapAroundTheWorkspace else { return boundaries.action != .fail }
                next = (next + order.count) % order.count
            }
            nativeFocus(order[next])
            return true
        case let .direction(direction):
            guard let node = subject.flatMap({ focusedWorkspace.root.find($0) }) else { return false }
            if boundaries.failIfFullscreen, focusedWorkspace.fullscreen != nil { return false }
            if let neighbor = neighbor(of: node, direction) {
                focus(neighbor)
                return true
            }
            if boundaries.scope == .allMonitorsOuterFrame,
               let monitor = monitor(.direction(direction), wrapAround: boundaries.action == .wrapAroundAllMonitors) {
                focusedMonitor = monitor
                if let entry = descend(focusedWorkspace.root, direction) { focus(entry) } else { focusRecent(in: focusedWorkspace) }
                return true
            }
            switch boundaries.action {
            case .stop, .createImplicitContainer: return true
            case .fail: return false
            case .wrapAroundTheWorkspace, .wrapAroundAllMonitors:
                if boundaries.action == .wrapAroundAllMonitors, let monitor = monitor(.direction(direction), wrapAround: true) {
                    focusedMonitor = monitor
                }
                guard let entry = descend(focusedWorkspace.root, direction) else { return false }
                focus(entry)
                return true
            }
        }
    }

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

    /// Down from `node` to a window, entering from the side opposite to `direction`.
    private func descend(_ node: WMNode, _ direction: Direction) -> WMNode? {
        guard node.isContainer else { return node }
        guard !node.children.isEmpty else { return nil }
        if node.orientation == direction.orientation {
            return descend(direction.offset > 0 ? node.children.first! : node.children.last!, direction)
        }
        return descend(node.recent ?? node.children.first!, direction)
    }

    /// AeroSpace's `move`: swap with a sibling window, enter a sibling container, or leave
    /// the container in that direction; at the workspace edge, by default, the root is
    /// wrapped in a new container along the direction.
    private func move(_ id: WindowID?, _ direction: Direction, _ boundaries: WMCommand.Boundaries) throws(InvalidConfig) -> Bool {
        let node = try tiledNode(id)
        let window = node.window!
        if boundaries.failIfFullscreen, workspace(of: window)?.fullscreen == window { return false }
        guard let parent = node.parent, let index = node.index else { return false }
        let target = index + direction.offset
        if parent.orientation == direction.orientation, parent.children.indices.contains(target) {
            let sibling = parent.children[target]
            if sibling.isContainer {
                let deep = deepTarget(sibling, direction.orientation)
                if deep.isContainer {
                    deep.insert(node, at: direction.offset > 0 ? 0 : deep.children.count)
                } else if let deepParent = deep.parent, let deepIndex = deep.index {
                    deepParent.insert(node, at: deepIndex + 1)
                }
            } else {
                WMNode.swap(node, sibling)
            }
            return true
        }
        // Leave: find the closest ancestor whose parent runs along the direction.
        var current = parent
        while let up = current.parent, up.orientation != direction.orientation { current = up }
        if let up = current.parent, let currentIndex = current.index {
            up.insert(node, at: currentIndex + (direction.offset > 0 ? 1 : 0))
            return true
        }
        // At the workspace edge.
        if boundaries.scope == .allMonitorsOuterFrame, let monitor = monitor(.direction(direction), wrapAround: false),
           let name = visible[monitor] {
            moveWindow(window, to: name, follow: true)
            return true
        }
        switch boundaries.action {
        case .stop: return true
        case .fail: return false
        default: break
        }
        let root = current
        guard root.children.count > 1 || root.orientation != direction.orientation else { return true }
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
        return true
    }

    private func deepTarget(_ node: WMNode, _ orientation: Orientation) -> WMNode {
        guard node.isContainer, node.orientation != orientation, let next = node.recent ?? node.children.last else { return node }
        return deepTarget(next, orientation)
    }

    private func swap(_ id: WindowID?, _ target: WMCommand.SwapTarget, swapFocus: Bool, wrapAround: Bool) throws(InvalidConfig) -> Bool {
        let node = try tiledNode(id)
        guard let root = workspace(of: node.window!)?.root else { return false }
        let other: WMNode?
        switch target {
        case let .direction(direction):
            other = neighbor(of: node, direction) ?? (wrapAround ? descend(root, direction) : nil)
        case .dfsNext, .dfsPrev:
            let order = root.windows
            guard let index = order.firstIndex(of: node.window!) else { return false }
            var next = index + (target == .dfsNext ? 1 : -1)
            if !order.indices.contains(next) {
                guard wrapAround else { return false }
                next = (next + order.count) % order.count
            }
            other = root.find(order[next])
        }
        guard let other, other !== node else { return false }
        WMNode.swap(node, other)
        if swapFocus, let window = other.window { focus(window) }
        return true
    }

    /// AeroSpace's `join-with`: the window and its neighbor in `direction` share a new
    /// container laid out across the current one.
    private func join(_ node: WMNode, _ direction: Direction) -> Bool {
        guard let parent = node.parent, parent.orientation == direction.orientation,
              let index = node.index, parent.children.indices.contains(index + direction.offset) else { return false }
        let sibling = parent.children[index + direction.offset]
        let container = WMNode(orientation: parent.orientation.opposite)
        parent.insert(container, at: min(index, index + direction.offset))
        container.weight = node.weight + sibling.weight
        for child in direction.offset > 0 ? [node, sibling] : [sibling, node] { container.insert(child) }
        node.markRecent()
        return true
    }

    /// Resizes along the axis the target names: the nearest tiles container running along
    /// it (smart: the window's own container; smart-opposite: the first one across it).
    private func resize(_ node: WMNode, _ target: WMCommand.ResizeTarget, _ amount: WMCommand.ResizeAmount) -> Bool {
        let base = node.parent?.orientation
        var current = node
        while let parent = current.parent {
            let matches = switch target {
            case .smart: true
            case .smartOpposite: parent.orientation != base
            case .width: parent.orientation == .horizontal
            case .height: parent.orientation == .vertical
            }
            if parent.layout == .tiles, parent.children.count > 1, matches { break }
            current = parent
        }
        guard let parent = current.parent, parent.lastLength > 0 else { return false }
        let others = parent.children.reduce(0) { $0 + ($1 === current ? 0 : $1.weight) }
        let total = others + current.weight
        let pixels = current.weight / total * parent.lastLength
        let wanted = switch amount {
        case let .add(delta): pixels + delta
        case let .set(value): value
        }
        let clamped = min(max(wanted, 50), parent.lastLength - 50 * Double(parent.children.count - 1))
        current.weight = clamped * others / max(parent.lastLength - clamped, 1)
        return true
    }

    private func balance(_ node: WMNode) {
        for child in node.children {
            child.weight = 1
            balance(child)
        }
    }

    private func layout(_ choices: [WMCommand.LayoutChoice], window id: WindowID?, workspace name: String?, root: Bool) throws(InvalidConfig) -> Bool {
        let workspace: WMWorkspace
        var window: WindowID?
        if let name {
            workspace = try self.workspace(named: name)
        } else {
            window = try self.window(id)
            guard let found = self.workspace(of: window!) else { throw InvalidConfig(message: "no window is focused") }
            workspace = found
        }
        let node = window.flatMap { workspace.root.find($0) }
        let container = root || name != nil ? workspace.root : node?.parent
        func isCurrent(_ choice: WMCommand.LayoutChoice) -> Bool {
            switch choice {
            case .floating: return window != nil && node == nil
            case .tiling: return node != nil
            case .tiles: return container?.layout == .tiles
            case .accordion: return container?.layout == .accordion
            case .horizontal: return container?.orientation == .horizontal
            case .vertical: return container?.orientation == .vertical
            case .hTiles: return container?.layout == .tiles && container?.orientation == .horizontal
            case .vTiles: return container?.layout == .tiles && container?.orientation == .vertical
            case .hAccordion: return container?.layout == .accordion && container?.orientation == .horizontal
            case .vAccordion: return container?.layout == .accordion && container?.orientation == .vertical
            }
        }
        guard let choice = choices.first(where: { !isCurrent($0) }) else { return false }
        switch choice {
        case .floating:
            guard let window, node != nil else { return false }
            detach(window, from: workspace)
            attachFloating(window, to: workspace)
            windows[window]?.floating = true
        case .tiling:
            guard let window, node == nil else { return false }
            releaseScratchpad(window)
            workspace.floating.removeAll { $0 == window }
            windows[window]?.floating = false
            insertTiled(window, into: workspace)
        default:
            guard let container else { throw InvalidConfig(message: "the window is floating") }
            switch choice {
            case .tiles, .hTiles, .vTiles: container.layout = .tiles
            case .accordion, .hAccordion, .vAccordion: container.layout = .accordion
            default: break
            }
            switch choice {
            case .horizontal, .hTiles, .hAccordion: container.orientation = .horizontal
            case .vertical, .vTiles, .vAccordion: container.orientation = .vertical
            default: break
            }
            // A nested container now running along its parent's axis is merged into it, which
            // is what the new orientation means and keeps containers alternating.
            if let grand = container.parent,
               grand.orientation == container.orientation, let index = container.index {
                for (offset, child) in container.children.enumerated() { grand.insert(child, at: index + offset) }
            }
        }
        return true
    }
}

extension CGRect {
    /// Edges rounded to whole points, so neighbors share an edge instead of overlapping.
    var pixelAligned: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        return CGRect(x: x0, y: y0, width: maxX.rounded() - x0, height: maxY.rounded() - y0)
    }
}
