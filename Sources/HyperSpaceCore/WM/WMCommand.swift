/// A window manager command. Names and arguments follow AeroSpace, so its bindings can be
/// copied over: `focus left`, `move-node-to-workspace 3`, `layout tiles accordion`...
public enum WMCommand: Sendable, Equatable {
    case focus(Direction)
    case move(Direction)
    /// Wraps the focused window and its neighbor into a new container.
    case joinWith(Direction)
    case resize(ResizeTarget, ResizeAmount)
    case balanceSizes
    case flattenWorkspaceTree
    /// Applies the first layout that isn't the current one, so `layout tiles accordion`
    /// toggles between the two.
    case layout([LayoutChoice])
    case fullscreen(Bool?)
    case workspace(WorkspaceTarget)
    case workspaceBackAndForth
    case moveNodeToWorkspace(WorkspaceTarget, focusFollows: Bool)
    case focusMonitor(MonitorTarget)
    case moveNodeToMonitor(MonitorTarget)
    case moveWorkspaceToMonitor(MonitorTarget)
    case close
    /// Runs a shell command (AeroSpace's `exec-and-forget`).
    case exec(String)
    case reloadConfig
    case enable(Bool?)

    public enum ResizeTarget: String, Sendable { case smart, width, height }

    public enum ResizeAmount: Sendable, Equatable {
        case add(Double), set(Double)
    }

    public enum LayoutChoice: String, Sendable, CaseIterable {
        case tiles, accordion, horizontal, vertical, tiling, floating
        case hTiles = "h_tiles", vTiles = "v_tiles", hAccordion = "h_accordion", vAccordion = "v_accordion"
    }

    public enum WorkspaceTarget: Sendable, Equatable {
        case named(String), next, prev
    }

    public enum MonitorTarget: Sendable, Equatable {
        case direction(Direction), next, prev
    }
}

extension WMCommand {
    /// Parses one command, e.g. `"move-node-to-workspace 3 --focus-follows-window"`.
    public init(parsing text: String) throws(InvalidConfig) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first else { throw InvalidConfig(message: "empty command") }
        let args = Array(words.dropFirst())
        func fail(_ usage: String) -> InvalidConfig { InvalidConfig(message: "'\(text)': usage: \(usage)") }
        func direction() throws(InvalidConfig) -> Direction {
            guard args.count == 1, let direction = Direction(rawValue: args[0]) else { throw fail("\(name) left|right|up|down") }
            return direction
        }
        func workspace(_ args: [String]) throws(InvalidConfig) -> WorkspaceTarget {
            guard args.count == 1 else { throw fail("\(name) <name>|next|prev") }
            return switch args[0] {
            case "next": .next
            case "prev": .prev
            default: .named(args[0])
            }
        }
        func monitor() throws(InvalidConfig) -> MonitorTarget {
            guard args.count == 1 else { throw fail("\(name) left|right|up|down|next|prev") }
            if let direction = Direction(rawValue: args[0]) { return .direction(direction) }
            switch args[0] {
            case "next": return .next
            case "prev": return .prev
            default: throw fail("\(name) left|right|up|down|next|prev")
            }
        }
        func onOff() throws(InvalidConfig) -> Bool? {
            switch args {
            case []: return nil
            case ["on"]: return true
            case ["off"]: return false
            case ["toggle"]: return nil
            default: throw fail("\(name) [on|off|toggle]")
            }
        }

        switch name {
        case "focus": self = .focus(try direction())
        case "move": self = .move(try direction())
        case "join-with": self = .joinWith(try direction())
        case "resize":
            guard args.count == 2, let target = ResizeTarget(rawValue: args[0]), let number = Double(args[1]) else {
                throw fail("resize smart|width|height [+|-]<number>")
            }
            self = .resize(target, args[1].hasPrefix("+") || args[1].hasPrefix("-") ? .add(number) : .set(number))
        case "balance-sizes": self = .balanceSizes
        case "flatten-workspace-tree": self = .flattenWorkspaceTree
        case "layout":
            let choices = args.compactMap(LayoutChoice.init(rawValue:))
            guard !choices.isEmpty, choices.count == args.count else {
                throw fail("layout \(LayoutChoice.allCases.map(\.rawValue).joined(separator: "|"))...")
            }
            self = .layout(choices)
        case "fullscreen": self = .fullscreen(try onOff())
        case "workspace": self = .workspace(try workspace(args))
        case "workspace-back-and-forth": self = .workspaceBackAndForth
        case "move-node-to-workspace":
            let follows = args.contains("--focus-follows-window")
            self = .moveNodeToWorkspace(try workspace(args.filter { $0 != "--focus-follows-window" }), focusFollows: follows)
        case "focus-monitor": self = .focusMonitor(try monitor())
        case "move-node-to-monitor": self = .moveNodeToMonitor(try monitor())
        case "move-workspace-to-monitor": self = .moveWorkspaceToMonitor(try monitor())
        case "close": self = .close
        case "exec-and-forget":
            let command = text.drop { !$0.isWhitespace }.drop { $0.isWhitespace }
            guard !command.isEmpty else { throw fail("exec-and-forget <shell command>") }
            self = .exec(String(command))
        case "reload-config": self = .reloadConfig
        case "enable": self = .enable(try onOff())
        default: throw InvalidConfig(message: "'\(text)': unknown window manager command '\(name)'")
        }
    }
}
