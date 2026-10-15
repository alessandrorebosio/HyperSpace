import Foundation

/// wm.toml validated and compiled: everything the window manager needs, plus the binding
/// modes as hotkey tables for the event tap.
public struct WMSettings: Sendable, Equatable {
    public var gaps = GapsConfig()
    public var accordionPadding = 30.0
    public var flattenContainers = true
    public var oppositeOrientationForNestedContainers = true
    public var rootLayout = ContainerLayout.tiles
    /// nil = auto: horizontal on wide monitors, vertical on tall ones.
    public var rootOrientation: Orientation?
    public var persistentWorkspaces: [String] = []
    public var workspaceToMonitor: [String: [String]] = [:]
    public var onWindowDetected: [Rule] = []
    public var afterStartup: WMScript?
    public var onFocusChanged: WMScript?
    public var onFocusedMonitorChanged: WMScript?
    public var onModeChanged: WMScript?
    public var execOnWorkspaceChange: [String] = []
    public var execInheritEnvVars = true
    /// `exec.env-vars`; the default puts Homebrew on the PATH, like AeroSpace.
    public var execEnvVars = ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:${PATH}"]
    public var focusFollowsMouse = false
    public var automaticallyUnhideMacosHiddenApps = false
    public var startAtLogin: Bool?
    public var autoReloadConfig = true
    /// Mode -> binding notation -> script, for `trigger-binding` and `list-modes`.
    public var modes: [String: [String: WMScript]] = ["main": [:]]
    /// Mode -> hotkey table for the event tap.
    public var hotkeys: [String: OutputTable] = [:]

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
        flattenContainers = config.enableNormalizationFlattenContainers
        oppositeOrientationForNestedContainers = config.enableNormalizationOppositeOrientationForNestedContainers
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
        guard (1...2).contains(config.configVersion) else { throw InvalidConfig(message: "config-version: use 1 or 2") }
        if let persistent = config.persistentWorkspaces {
            guard config.configVersion >= 2 else {
                throw InvalidConfig(message: "persistent-workspaces: needs config-version = 2")
            }
            persistentWorkspaces = persistent
        }
        workspaceToMonitor = config.workspaceToMonitorForceAssignment
        func script(_ commands: [String], _ path: String) throws(InvalidConfig) -> WMScript? {
            guard !commands.isEmpty else { return nil }
            do { return try WMScript(commands: commands) } catch { throw InvalidConfig(message: "\(path): \(error.message)") }
        }
        afterStartup = try script(config.afterStartupCommand, "after-startup-command")
        onFocusChanged = try script(config.onFocusChanged, "on-focus-changed")
        onFocusedMonitorChanged = try script(config.onFocusedMonitorChanged, "on-focused-monitor-changed")
        onModeChanged = try script(config.onModeChanged, "on-mode-changed")
        execOnWorkspaceChange = config.execOnWorkspaceChange
        execInheritEnvVars = config.execInheritEnvVars
        if let vars = config.execEnvVars { execEnvVars = vars }
        focusFollowsMouse = config.focusFollowsMouse
        automaticallyUnhideMacosHiddenApps = config.automaticallyUnhideMacosHiddenApps
        startAtLogin = config.startAtLogin
        autoReloadConfig = config.autoReloadConfig
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

        guard WMKeys.presets[config.keyMappingPreset] != nil else {
            throw InvalidConfig(message: "key-mapping.preset: '\(config.keyMappingPreset)'; use qwerty, dvorak or colemak")
        }
        modes = [:]
        for (mode, bindings) in config.modes {
            var table = OutputTable.hotkeys
            var scripts: [String: WMScript] = [:]
            for (notation, commands) in bindings.sorted(by: { $0.key < $1.key }) {
                let path = "mode.\(mode).binding.\(notation)"
                let combo = try WMKeys.combo(notation, preset: config.keyMappingPreset, notation: config.keyNotationToKeyCode, path: path)
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
        }
        if modes["main"] == nil { modes["main"] = [:] }
        // config-version 1 infers persistent workspaces from the bindings, as AeroSpace does.
        if config.configVersion == 1 {
            persistentWorkspaces = modes.values.flatMap(\.values).flatMap(\.commands).compactMap { command in
                if case let .workspace(.named(name), _, _, _) = command { return name }
                return nil
            }
        }
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
