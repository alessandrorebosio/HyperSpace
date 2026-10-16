/// A window manager command, with AeroSpace's names, arguments and flags, so an AeroSpace
/// config or script works unchanged.
public indirect enum WMCommand: Sendable, Equatable {
    case focus(FocusTarget, Boundaries)
    case move(Direction, Boundaries, window: WindowID?)
    case swap(SwapTarget, swapFocus: Bool, wrapAround: Bool, window: WindowID?)
    case joinWith(Direction, window: WindowID?)
    case resize(ResizeTarget, ResizeAmount, window: WindowID?)
    case balanceSizes(workspace: String?)
    case flattenWorkspaceTree(workspace: String?)
    /// Applies the first layout that isn't the current one: `layout tiles accordion` toggles.
    case layout([LayoutChoice], window: WindowID?, workspace: String?, root: Bool, failIfNoop: Bool)
    case fullscreen(Bool?, noOuterGaps: Bool, window: WindowID?, failIfNoop: Bool)
    case macosNativeFullscreen(Bool?, window: WindowID?)
    case macosNativeMinimize(window: WindowID?)
    case workspace(WorkspaceTarget, autoBackAndForth: Bool, wrapAround: Bool, failIfNoop: Bool)
    case workspaceBackAndForth
    case summonWorkspace(String, failIfNoop: Bool)
    case moveNodeToWorkspace(WorkspaceTarget, focusFollows: Bool, wrapAround: Bool, window: WindowID?, failIfNoop: Bool)
    case focusMonitor(MonitorTarget, wrapAround: Bool)
    case moveNodeToMonitor(MonitorTarget, focusFollows: Bool, wrapAround: Bool, window: WindowID?)
    /// `swap` (AeroSpace's way): the workspace it covers comes over in exchange. Without
    /// (`--no-swap`, HyperSpace's own) that one just hides, and the monitor left shows the
    /// one used last there.
    case moveWorkspaceToMonitor(MonitorTarget, wrapAround: Bool, workspace: String?, swap: Bool)
    /// HyperSpace's own: summons or puts away an app's scratchpad window, by bundle id.
    /// `new`: a new window of the app (its ⌘N menu item) is the scratchpad, if it has one.
    case scratchpad(String, new: Bool)
    /// HyperSpace's own: the window manager leaves out (`true`), or takes back (`false`), the
    /// displays matching the patterns, as if they were disconnected. nil toggles.
    case ignoreMonitor(Bool?, patterns: [String])
    /// HyperSpace's own: changes a display's setting over DDC (`monitor-brightness`,
    /// `monitor-volume`, `monitor-input`), on the displays matching the patterns, else the
    /// focused one.
    case monitorSetting(MonitorSetting, monitor: [String]?)
    case focusBackAndForth
    case close(quitIfLastWindow: Bool, window: WindowID?)
    case closeAllWindowsButCurrent(quitIfLastWindow: Bool)
    case moveMouse(MousePosition, failIfNoop: Bool)
    case mode(String)
    case triggerBinding(String, mode: String)
    case volume(Volume)
    /// Runs a shell command (`exec-and-forget`).
    case exec(String)
    case reloadConfig
    case enable(Bool?, failIfNoop: Bool)
    case list(ListQuery)
    case test(String, TestOperator, String, negate: Bool)
    case result(Bool)
    case echo(String)

    public enum FocusTarget: Sendable, Equatable {
        case direction(Direction), dfsNext, dfsPrev, window(WindowID), dfsIndex(Int)
    }

    public struct Boundaries: Sendable, Equatable {
        public enum Scope: String, Sendable { case workspace, allMonitorsOuterFrame = "all-monitors-outer-frame" }
        public enum Action: String, Sendable {
            case stop, fail, wrapAroundTheWorkspace = "wrap-around-the-workspace"
            case wrapAroundAllMonitors = "wrap-around-all-monitors", createImplicitContainer = "create-implicit-container"
        }

        public var scope = Scope.workspace
        public var action: Action
        public var failIfFullscreen = false
        public var ignoreFloating = false

        public init(action: Action) { self.action = action }
    }

    public enum SwapTarget: Sendable, Equatable { case direction(Direction), dfsNext, dfsPrev }
    public enum ResizeTarget: String, Sendable { case smart, smartOpposite = "smart-opposite", width, height }
    public enum ResizeAmount: Sendable, Equatable { case add(Double), set(Double) }

    public enum LayoutChoice: String, Sendable, CaseIterable {
        case tiles, accordion, horizontal, vertical, tiling, floating
        case hTiles = "h_tiles", vTiles = "v_tiles", hAccordion = "h_accordion", vAccordion = "v_accordion"
    }

    public enum WorkspaceTarget: Sendable, Equatable { case named(String), next, prev }

    public enum MonitorTarget: Sendable, Equatable {
        case direction(Direction), next, prev
        /// `main`, `secondary`, a 1-based number from the left, or a name regex.
        case patterns([String])
    }

    /// Levels are in percent of the display's maximum.
    public enum MonitorSetting: Sendable, Equatable {
        case brightness(ResizeAmount)
        case volume(ResizeAmount)
        case muteToggle
        /// An MCCS input source code.
        case input(UInt8)

        /// MCCS input source codes by name. USB-C has no standard code: 0x1b is Dell's and
        /// LG's; a number works for any other.
        public static let inputs: [String: UInt8] = [
            "vga1": 0x01, "vga2": 0x02, "dvi1": 0x03, "dvi2": 0x04, "dp1": 0x0f, "dp2": 0x10,
            "hdmi1": 0x11, "hdmi2": 0x12, "usb-c": 0x1b,
        ]
    }

    public enum MousePosition: String, Sendable {
        case monitorLazyCenter = "monitor-lazy-center", monitorForceCenter = "monitor-force-center"
        case windowLazyCenter = "window-lazy-center", windowForceCenter = "window-force-center"
    }

    public enum Volume: Sendable, Equatable { case up, down, muteToggle, muteOn, muteOff, set(Int) }

    public enum TestOperator: String, Sendable { case equals = "=", matches = "~=" }

    public struct ListQuery: Sendable, Equatable {
        public enum Kind: String, Sendable { case windows = "list-windows", workspaces = "list-workspaces", monitors = "list-monitors", apps = "list-apps", modes = "list-modes" }
        public var kind: Kind
        /// Flag -> values, e.g. `--workspace` -> ["1", "focused"]; `--focused` -> [].
        public var filters: [String: [String]] = [:]
        public var format: String?
        public var count = false
        public var json = false
    }
}

// MARK: - Parsing

extension WMCommand {
    /// Parses one command from its words, e.g. `["move-node-to-workspace", "3", "--focus-follows-window"]`.
    public init(words: [String]) throws(InvalidConfig) {
        guard let name = words.first else { throw InvalidConfig(message: "empty command") }
        var p = ArgParser(name: name, args: Array(words.dropFirst()))
        self = try WMCommand.parse(name, &p)
        try p.finish()
    }

    /// Parses one command line (no `;`, `&&`, `||`: see `WMScript` for those).
    public init(parsing text: String) throws(InvalidConfig) {
        try self.init(words: try Shell.words(text))
    }

    private static func parse(_ name: String, _ p: inout ArgParser) throws(InvalidConfig) -> WMCommand {
        switch name {
        case "focus":
            if let id = try p.value("--window-id") { return .focus(.window(try p.windowID(id)), Boundaries(action: .stop)) }
            if let index = try p.value("--dfs-index") {
                guard let index = Int(index) else { throw p.fail("--dfs-index <number>") }
                return .focus(.dfsIndex(index), Boundaries(action: .stop))
            }
            var boundaries = try p.boundaries(defaultAction: .stop)
            boundaries.ignoreFloating = p.flag("--ignore-floating")
            if p.flag("--wrap-around") { boundaries.action = .wrapAroundTheWorkspace }
            _ = p.flag("--fail-if-macos-native-fullscreen")
            let target = try p.positional("(left|down|up|right|dfs-next|dfs-prev)")
            switch target {
            case "dfs-next": return .focus(.dfsNext, boundaries)
            case "dfs-prev": return .focus(.dfsPrev, boundaries)
            default: return .focus(.direction(try p.direction(target)), boundaries)
            }
        case "move":
            let window = try p.windowFlag()
            let boundaries = try p.boundaries(defaultAction: .createImplicitContainer)
            _ = p.flag("--fail-if-macos-native-fullscreen")
            return .move(try p.direction(try p.positional("(left|down|up|right)")), boundaries, window: window)
        case "swap":
            let window = try p.windowFlag(), swapFocus = p.flag("--swap-focus"), wrap = p.flag("--wrap-around")
            let target = try p.positional("(left|down|up|right|dfs-next|dfs-prev)")
            let swapTarget: SwapTarget = switch target {
            case "dfs-next": .dfsNext
            case "dfs-prev": .dfsPrev
            default: .direction(try p.direction(target))
            }
            return .swap(swapTarget, swapFocus: swapFocus, wrapAround: wrap, window: window)
        case "join-with":
            let window = try p.windowFlag()
            return .joinWith(try p.direction(try p.positional("(left|down|up|right)")), window: window)
        case "resize":
            let window = try p.windowFlag()
            guard let target = ResizeTarget(rawValue: try p.positional("(smart|smart-opposite|width|height) [+|-]<number>")) else {
                throw p.fail("(smart|smart-opposite|width|height) [+|-]<number>")
            }
            let amount = try p.positional("[+|-]<number>")
            guard let number = Double(amount) else { throw p.fail("(smart|smart-opposite|width|height) [+|-]<number>") }
            return .resize(target, amount.hasPrefix("+") || amount.hasPrefix("-") ? .add(number) : .set(number), window: window)
        case "balance-sizes":
            return .balanceSizes(workspace: try p.value("--workspace"))
        case "flatten-workspace-tree":
            return .flattenWorkspaceTree(workspace: try p.value("--workspace"))
        case "layout":
            let window = try p.windowFlag(), workspace = try p.value("--workspace"), root = p.flag("--root"), noop = p.flag("--fail-if-noop")
            let choices = try p.rest().map { word throws(InvalidConfig) in
                guard let choice = LayoutChoice(rawValue: word) else {
                    throw p.fail("(\(LayoutChoice.allCases.map(\.rawValue).joined(separator: "|")))...")
                }
                return choice
            }
            guard !choices.isEmpty else { throw p.fail("(\(LayoutChoice.allCases.map(\.rawValue).joined(separator: "|")))...") }
            return .layout(choices, window: window, workspace: workspace, root: root, failIfNoop: noop)
        case "fullscreen":
            let window = try p.windowFlag(), noGaps = p.flag("--no-outer-gaps"), noop = p.flag("--fail-if-noop")
            return .fullscreen(try p.onOff(), noOuterGaps: noGaps, window: window, failIfNoop: noop)
        case "macos-native-fullscreen":
            let window = try p.windowFlag()
            _ = p.flag("--fail-if-noop")
            return .macosNativeFullscreen(try p.onOff(), window: window)
        case "macos-native-minimize":
            return .macosNativeMinimize(window: try p.windowFlag())
        case "workspace":
            let auto = p.flag("--auto-back-and-forth"), wrap = p.flag("--wrap-around"), noop = p.flag("--fail-if-noop")
            _ = p.flag("--no-stdin")
            return .workspace(try p.workspaceTarget(), autoBackAndForth: auto, wrapAround: wrap, failIfNoop: noop)
        case "workspace-back-and-forth":
            return .workspaceBackAndForth
        case "summon-workspace":
            let noop = p.flag("--fail-if-noop")
            return .summonWorkspace(try p.positional("<workspace>"), failIfNoop: noop)
        case "move-node-to-workspace":
            let follows = p.flag("--focus-follows-window"), wrap = p.flag("--wrap-around"), noop = p.flag("--fail-if-noop")
            let window = try p.windowFlag()
            _ = p.flag("--no-stdin")
            return .moveNodeToWorkspace(try p.workspaceTarget(), focusFollows: follows, wrapAround: wrap, window: window, failIfNoop: noop)
        case "focus-monitor":
            let wrap = p.flag("--wrap-around")
            return .focusMonitor(try p.monitorTarget(), wrapAround: wrap)
        case "move-node-to-monitor":
            let window = try p.windowFlag(), follows = p.flag("--focus-follows-window"), wrap = p.flag("--wrap-around")
            _ = p.flag("--fail-if-noop")
            return .moveNodeToMonitor(try p.monitorTarget(), focusFollows: follows, wrapAround: wrap, window: window)
        case "move-workspace-to-monitor":
            let workspace = try p.value("--workspace"), wrap = p.flag("--wrap-around"), noSwap = p.flag("--no-swap")
            return .moveWorkspaceToMonitor(try p.monitorTarget(), wrapAround: wrap, workspace: workspace, swap: !noSwap)
        case "scratchpad":
            let new = p.flag("--new")
            return .scratchpad(try p.positional("<app-bundle-id>"), new: new)
        case "ignore-monitor":
            let usage = "(on|off|toggle) <monitor-pattern>..."
            let state: Bool?
            switch try p.positional(usage) {
            case "on": state = true
            case "off": state = false
            case "toggle": state = nil
            default: throw p.fail(usage)
            }
            let patterns = try p.rest()
            guard !patterns.isEmpty else { throw p.fail(usage) }
            return .ignoreMonitor(state, patterns: patterns)
        case "monitor-brightness", "monitor-volume":
            let monitor = try p.value("--monitor").map { [$0] }
            let usage = name == "monitor-volume" ? "(mute-toggle|[+|-]<percent>) [--monitor <monitor-pattern>]" : "[+|-]<percent> [--monitor <monitor-pattern>]"
            let amount = try p.positional(usage)
            if name == "monitor-volume", amount == "mute-toggle" { return .monitorSetting(.muteToggle, monitor: monitor) }
            guard let number = Double(amount), (-100...100).contains(number) else { throw p.fail(usage) }
            let level: ResizeAmount = amount.hasPrefix("+") || amount.hasPrefix("-") ? .add(number) : .set(number)
            return .monitorSetting(name == "monitor-volume" ? .volume(level) : .brightness(level), monitor: monitor)
        case "monitor-input":
            let monitor = try p.value("--monitor").map { [$0] }
            let usage = "(\(MonitorSetting.inputs.keys.sorted().joined(separator: "|"))|<code>) [--monitor <monitor-pattern>]"
            let word = try p.positional(usage).lowercased()
            let code = MonitorSetting.inputs[word]
                ?? (word.hasPrefix("0x") ? UInt8(word.dropFirst(2), radix: 16) : UInt8(word))
            guard let code else { throw p.fail(usage) }
            return .monitorSetting(.input(code), monitor: monitor)
        case "focus-back-and-forth":
            return .focusBackAndForth
        case "close":
            let quit = p.flag("--quit-if-last-window")
            return .close(quitIfLastWindow: quit, window: try p.windowFlag())
        case "close-all-windows-but-current":
            return .closeAllWindowsButCurrent(quitIfLastWindow: p.flag("--quit-if-last-window"))
        case "move-mouse":
            let noop = p.flag("--fail-if-noop")
            guard let position = MousePosition(rawValue: try p.positional("<mouse-position>")) else {
                throw p.fail("(monitor-lazy-center|monitor-force-center|window-lazy-center|window-force-center)")
            }
            return .moveMouse(position, failIfNoop: noop)
        case "mode":
            return .mode(try p.positional("<binding-mode>"))
        case "trigger-binding":
            guard let mode = try p.value("--mode") else { throw p.fail("--mode <mode-id> <binding>") }
            return .triggerBinding(try p.positional("<binding>"), mode: mode)
        case "volume":
            _ = p.flag("--no-gui")
            switch try p.positional("(up|down|mute-toggle|mute-on|mute-off|set <number>)") {
            case "up": return .volume(.up)
            case "down": return .volume(.down)
            case "mute-toggle": return .volume(.muteToggle)
            case "mute-on": return .volume(.muteOn)
            case "mute-off": return .volume(.muteOff)
            case "set":
                guard let level = Int(try p.positional("<number>")), (0...100).contains(level) else { throw p.fail("set <0-100>") }
                return .volume(.set(level))
            default: throw p.fail("(up|down|mute-toggle|mute-on|mute-off|set <number>)")
            }
        case "exec-and-forget":
            let command = try p.rest().joined(separator: " ")
            guard !command.isEmpty else { throw p.fail("<bash-script>") }
            return .exec(command)
        case "reload-config":
            _ = p.flag("--no-gui")
            _ = p.flag("--dry-run")
            return .reloadConfig
        case "enable":
            let noop = p.flag("--fail-if-noop")
            return .enable(try p.onOff(), failIfNoop: noop)
        case "list-windows", "list-workspaces", "list-monitors", "list-apps", "list-modes":
            return .list(try p.listQuery(ListQuery.Kind(rawValue: name)!))
        case "test", "test-not":
            let lhs = try p.positional("<lhs> (=|~=) <rhs>")
            guard let op = TestOperator(rawValue: try p.positional("<lhs> (=|~=) <rhs>")) else { throw p.fail("<lhs> (=|~=) <rhs>") }
            return .test(lhs, op, try p.positional("<lhs> (=|~=) <rhs>"), negate: name == "test-not")
        case "true": return .result(true)
        case "false": return .result(false)
        case "echo": return .echo(try p.rest().joined(separator: " "))
        default:
            throw InvalidConfig(message: "unknown command '\(name)'")
        }
    }
}

/// Arguments of one command: flags can appear anywhere, positionals in order.
private struct ArgParser {
    let name: String
    var args: [String]

    func fail(_ usage: String) -> InvalidConfig {
        InvalidConfig(message: "\(name): usage: \(name) \(usage)")
    }

    mutating func flag(_ flag: String) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        args.remove(at: index)
        return true
    }

    mutating func value(_ flag: String) throws(InvalidConfig) -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count else { throw InvalidConfig(message: "\(name): \(flag) needs a value") }
        let value = args[index + 1]
        args.removeSubrange(index...index + 1)
        return value
    }

    mutating func positional(_ usage: String) throws(InvalidConfig) -> String {
        _ = flag("--")
        guard let first = args.first(where: { !$0.hasPrefix("--") }), let index = args.firstIndex(of: first) else { throw fail(usage) }
        args.remove(at: index)
        return first
    }

    mutating func rest() throws(InvalidConfig) -> [String] {
        _ = flag("--")
        defer { args = [] }
        return args
    }

    func finish() throws(InvalidConfig) {
        if let extra = args.first { throw InvalidConfig(message: "\(name): unexpected argument '\(extra)'") }
    }

    func direction(_ word: String) throws(InvalidConfig) -> Direction {
        guard let direction = Direction(rawValue: word) else { throw fail("(left|down|up|right)") }
        return direction
    }

    func windowID(_ text: String) throws(InvalidConfig) -> WindowID {
        guard let id = WindowID(text) else { throw InvalidConfig(message: "\(name): '\(text)' isn't a window id") }
        return id
    }

    mutating func windowFlag() throws(InvalidConfig) -> WindowID? {
        try value("--window-id").map { text throws(InvalidConfig) in try windowID(text) }
    }

    mutating func onOff() throws(InvalidConfig) -> Bool? {
        guard let word = args.first(where: { !$0.hasPrefix("--") }) else { return nil }
        args.removeAll { $0 == word }
        switch word {
        case "on": return true
        case "off": return false
        case "toggle": return nil
        default: throw fail("[on|off|toggle]")
        }
    }

    mutating func boundaries(defaultAction: WMCommand.Boundaries.Action) throws(InvalidConfig) -> WMCommand.Boundaries {
        var boundaries = WMCommand.Boundaries(action: defaultAction)
        if let scope = try value("--boundaries") {
            guard let parsed = WMCommand.Boundaries.Scope(rawValue: scope) else { throw fail("--boundaries (workspace|all-monitors-outer-frame)") }
            boundaries.scope = parsed
        }
        if let action = try value("--boundaries-action") {
            guard let parsed = WMCommand.Boundaries.Action(rawValue: action) else {
                throw fail("--boundaries-action (stop|fail|wrap-around-the-workspace|wrap-around-all-monitors|create-implicit-container)")
            }
            boundaries.action = parsed
        }
        boundaries.failIfFullscreen = flag("--fail-if-fullscreen")
        return boundaries
    }

    mutating func workspaceTarget() throws(InvalidConfig) -> WMCommand.WorkspaceTarget {
        switch try positional("(<workspace-name>|next|prev)") {
        case "next": .next
        case "prev": .prev
        case let name: .named(name)
        }
    }

    mutating func monitorTarget() throws(InvalidConfig) -> WMCommand.MonitorTarget {
        let words = try rest()
        guard let first = words.first else { throw fail("(left|down|up|right|next|prev|<monitor-pattern>...)") }
        if words.count == 1, let direction = Direction(rawValue: first) { return .direction(direction) }
        if words == ["next"] { return .next }
        if words == ["prev"] { return .prev }
        return .patterns(words)
    }

    mutating func listQuery(_ kind: WMCommand.ListQuery.Kind) throws(InvalidConfig) -> WMCommand.ListQuery {
        var query = WMCommand.ListQuery(kind: kind)
        query.format = try value("--format")
        query.count = flag("--count")
        query.json = flag("--json")
        var current: String?
        for word in try rest() {
            if word.hasPrefix("--") {
                current = word
                query.filters[word, default: []] = []
            } else if let flag = current {
                query.filters[flag, default: []].append(word)
            } else {
                throw InvalidConfig(message: "\(name): unexpected argument '\(word)'")
            }
        }
        return query
    }
}
