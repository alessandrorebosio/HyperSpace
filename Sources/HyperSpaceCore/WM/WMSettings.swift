import Foundation

/// wm.toml validated and compiled: everything the window manager needs, plus the binding
/// modes as hotkey tables for the event tap.
public struct WMSettings: Sendable, Equatable {
    public var gaps = GapsConfig()
    public var accordionPadding = 30.0
    public var rootLayout = ContainerLayout.tiles
    /// nil = auto: horizontal on wide monitors, vertical on tall ones.
    public var rootOrientation: Orientation?
    public var persistentWorkspaces: [String] = []
    public var workspaceToMonitor: [String: [String]] = [:]
    public var onWindowDetected: [Rule] = []
    public var onFocusChanged: WMScript?
    public var onFocusedMonitorChanged: WMScript?
    public var onModeChanged: WMScript?
    public var execOnWorkspaceChange: [String] = []
    public var focusFollowsMouse = false
    public var automaticallyUnhideMacosHiddenApps = false
    /// Where a scratchpad with no workspace of its own goes when put away; left out of
    /// `workspace next/prev`.
    public var scratchpadFallbackWorkspace = "Scratch"
    /// Displays whose input (read over DDC) isn't the Mac's are left out, as if disconnected.
    public var detectMonitorInput = false
    /// Shows the bindings of a mode other than main while it's on.
    public var showModeBindings = false
    /// `show-bindings-on-hold`: holding exactly these modifiers, and no key, for a while shows
    /// the main bindings that use them.
    public var bindingsOnHold: BindingsOnHold?
    /// Mode -> its bindings as written (notation, commands), sorted, for that list.
    public var bindingTexts: [String: [BindingText]] = [:]
    /// Mode -> binding notation -> script, for `trigger-binding` and `list-modes`.
    public var modes: [String: [String: WMScript]] = ["main": [:]]
    /// Mode -> hotkey table for the event tap.
    public var hotkeys: [String: OutputTable] = [:]

    public struct BindingsOnHold: Sendable, Equatable {
        public var hint: HoldHint
        /// The modifiers as written, for the panel's title.
        public var title: String
        /// The main bindings with exactly these modifiers, by their key alone.
        public var bindings: [BindingText]
    }

    public struct BindingText: Sendable, Equatable {
        public var key: String
        public var commands: String
    }

    public struct Rule: Sendable, Equatable {
        public var condition: Condition
        public var checkFurtherCallbacks: Bool
        public var run: WMScript
    }

    public enum Condition: Sendable, Equatable {
        case always
        case script(WMScript)
        case legacy(appID: String?, appNameRegex: String?, windowTitleRegex: String?, workspace: String?, duringStartup: Bool?)
    }

    public init() {}

    public init(_ config: WMConfig) throws(InvalidConfig) {
        gaps = config.gaps
        accordionPadding = Double(config.accordionPadding)
        switch config.defaultRootContainerLayout {
        case "tiles": rootLayout = .tiles
        case "accordion": rootLayout = .accordion
        case let other: throw InvalidConfig(message: "default-root-container-layout: '\(other)'; use tiles or accordion")
        }
        switch config.defaultRootContainerOrientation {
        case "auto": rootOrientation = nil
        case "horizontal": rootOrientation = .horizontal
        case "vertical": rootOrientation = .vertical
        case let other: throw InvalidConfig(message: "default-root-container-orientation: '\(other)'; use horizontal, vertical or auto")
        }
        workspaceToMonitor = config.workspaceToMonitorForceAssignment
        func script(_ commands: [String], _ path: String) throws(InvalidConfig) -> WMScript? {
            guard !commands.isEmpty else { return nil }
            do { return try WMScript(commands: commands) } catch { throw InvalidConfig(message: "\(path): \(error.message)") }
        }
        onFocusChanged = try script(config.onFocusChanged, "on-focus-changed")
        onFocusedMonitorChanged = try script(config.onFocusedMonitorChanged, "on-focused-monitor-changed")
        onModeChanged = try script(config.onModeChanged, "on-mode-changed")
        execOnWorkspaceChange = config.execOnWorkspaceChange
        focusFollowsMouse = config.focusFollowsMouse
        automaticallyUnhideMacosHiddenApps = config.automaticallyUnhideMacosHiddenApps
        scratchpadFallbackWorkspace = config.scratchpadFallbackWorkspace
        detectMonitorInput = config.detectMonitorInput
        showModeBindings = config.showModeBindings
        guard !scratchpadFallbackWorkspace.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw InvalidConfig(message: "scratchpad-fallback-workspace: needs a workspace name")
        }
        guard (0...1000).contains(config.accordionPadding) else { throw InvalidConfig(message: "accordion-padding: must be between 0 and 1000") }

        for (i, rule) in config.onWindowDetected.enumerated() {
            let path = "on-window-detected[\(i)]"
            let condition: Condition
            switch rule.condition {
            case nil:
                guard rule.checkFurtherCallbacks else {
                    throw InvalidConfig(message: "\(path): omitting 'if' is error prone; use if = 'true' (and check-further-callbacks = true if you meant it)")
                }
                condition = .always
            case let .script(text)?:
                condition = .script(try script([text], "\(path).if")!)
            case let .legacy(appID, appName, title, workspace, startup)?:
                for regex in [appName, title].compactMap({ $0 }) where (try? NSRegularExpression(pattern: regex)) == nil {
                    throw InvalidConfig(message: "\(path).if: '\(regex)' isn't a valid regex")
                }
                condition = .legacy(appID: appID, appNameRegex: appName, windowTitleRegex: title, workspace: workspace, duringStartup: startup)
            }
            guard let run = try script(rule.run, "\(path).run") else { throw InvalidConfig(message: "\(path).run: no command") }
            onWindowDetected.append(Rule(condition: condition, checkFurtherCallbacks: rule.checkFurtherCallbacks, run: run))
        }

        modes = [:]
        for (mode, bindings) in config.modes {
            var table = OutputTable.hotkeys
            var scripts: [String: WMScript] = [:]
            for (notation, commands) in bindings.sorted(by: { $0.key < $1.key }) {
                let path = "mode.\(mode).binding.\(notation)"
                let combo = try WMKeys.combo(notation, path: path)
                guard let script = try script(commands, path) else { throw InvalidConfig(message: "\(path): no command") }
                for command in script.commands {
                    if case let .mode(target) = command, config.modes[target] == nil {
                        throw InvalidConfig(message: "\(path): there is no [mode.\(target).binding]")
                    }
                }
                scripts[notation] = script
                let outputs = commands.map(Output.wm)
                table[Hotkeys.index(code: combo.key.code, modifiers: combo.modifiers)] = outputs.count == 1 ? outputs[0] : .sequence(outputs)
            }
            modes[mode] = scripts
            hotkeys[mode] = table
            bindingTexts[mode] = bindings.sorted { $0.key < $1.key }.map { BindingText(key: $0.key, commands: $0.value.joined(separator: "; ")) }
        }
        if modes["main"] == nil { modes["main"] = [:] }
        if let hold = config.showBindingsOnHold {
            let path = "show-bindings-on-hold"
            var modifiers: Modifiers = []
            for part in hold.modifiers.split(separator: "-").map(String.init) {
                guard let modifier = WMKeys.modifiers[part] else {
                    throw InvalidConfig(message: "\(path).modifiers: unknown modifier '\(part)'; use cmd, alt, ctrl, shift")
                }
                modifiers.insert(modifier)
            }
            guard !modifiers.isEmpty else { throw InvalidConfig(message: "\(path).modifiers: needs at least one modifier") }
            guard (100...10_000).contains(hold.delayMs) else { throw InvalidConfig(message: "\(path).delay-ms: must be between 100 and 10000") }
            let bindings = (config.modes["main"] ?? [:]).sorted { $0.key < $1.key }.compactMap { notation, commands -> BindingText? in
                guard let combo = try? WMKeys.combo(notation, path: path), combo.modifiers == modifiers else { return nil }
                return BindingText(key: String(notation.split(separator: "-").last ?? ""), commands: commands.joined(separator: "; "))
            }
            bindingsOnHold = BindingsOnHold(hint: HoldHint(modifiers: modifiers, delayNs: UInt64(hold.delayMs) * 1_000_000),
                                            title: hold.modifiers, bindings: bindings)
        }
        // Without persistent-workspaces, the workspaces named in bindings and the ones assigned
        // to a monitor stay alive.
        persistentWorkspaces = config.persistentWorkspaces ?? Array(Set(modes.values.flatMap(\.values).flatMap(\.commands).compactMap { command in
            if case let .workspace(.named(name), _, _, _) = command { return name }
            return nil
        } + workspaceToMonitor.keys)).sorted()
    }

    /// Gaps resolved for one monitor.
    public func resolvedGaps(for monitor: WMMonitor, in monitors: [WMMonitor]) -> (horizontal: Double, vertical: Double, left: Double, bottom: Double, top: Double, right: Double) {
        func value(_ gap: GapValue) -> Double {
            Double(gap.perMonitor.first { WMMonitor.matches($0.pattern, monitor, in: monitors) }?.value ?? gap.fallback)
        }
        return (value(gaps.innerHorizontal), value(gaps.innerVertical), value(gaps.outerLeft),
                value(gaps.outerBottom), value(gaps.outerTop), value(gaps.outerRight))
    }
}

extension WMMonitor {
    /// AeroSpace monitor patterns: `main`, `secondary` (the other one of two), a 1-based
    /// number from the left, or a case-insensitive regex on the monitor's name.
    public static func matches(_ pattern: String, _ monitor: WMMonitor, in monitors: [WMMonitor]) -> Bool {
        switch pattern {
        case "main": return monitor.isMain
        case "secondary": return monitors.count == 2 && !monitor.isMain
        default:
            if let number = Int(pattern) {
                let sorted = monitors.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
                return sorted.indices.contains(number - 1) && sorted[number - 1].id == monitor.id
            }
            return monitor.name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
