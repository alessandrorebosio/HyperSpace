import AppKit
import HyperSpaceCore

extension WindowManager {
    // MARK: - Commands

    /// Runs commands from a hotkey or a callback, AeroSpace shell syntax included
    /// (`a; b`, `a && b`, `a || b`). Returns an error message for the user, if any.
    @discardableResult
    public func run(_ text: String, window: WindowID? = nil) -> String? {
        do {
            return execute(try WMScript(parsing: text), window: window).error
        } catch {
            return error.message
        }
    }

    /// Runs one command from `hsctl`, with its words as given (no shell parsing, so quoted
    /// arguments arrive intact).
    public func run(words: [String]) -> (ok: Bool, output: String, error: String?) {
        do {
            let result = execute(.command(try WMCommand(words: words)), window: nil)
            return (result.ok, result.output, result.error)
        } catch {
            return (false, "", error.message)
        }
    }

    struct Result {
        var ok = true
        var output = ""
        var error: String?
    }

    var focusState: FocusState? {
        model.map { ($0.focused, $0.focusedWorkspace.name, $0.focusedMonitor) }
    }

    func execute(_ script: WMScript, window: WindowID?) -> Result {
        var result = Result()
        guard let before = focusState else {
            result.ok = false
            result.error = "the window manager is off (wm.toml is empty)"
            return result
        }
        result.ok = script.run { command in
            do throws(InvalidConfig) {
                let (ok, output) = try perform(command, window: window)
                if let output, !output.isEmpty { result.output += (result.output.isEmpty ? "" : "\n") + output }
                return ok
            } catch {
                result.error = error.message
                return false
            }
        }
        afterCommands(since: before)
        return result
    }

    /// One command. The model handles the tree, workspaces and monitors; the rest talks to
    /// other processes or the system and is done here.
    private func perform(_ command: WMCommand, window: WindowID?) throws(InvalidConfig) -> (Bool, String?) {
        guard let model else { return (false, nil) }
        switch command {
        case let .exec(script):
            exec(["/bin/bash", "-c", script], extra: window.map { ["AEROSPACE_WINDOW_ID": String($0)] } ?? [:])
        case .reloadConfig:
            handlers.reloadConfig()
        case let .enable(on, failIfNoop):
            if failIfNoop, on == true { return (false, nil) } // already on: we're running
            handlers.enable(on)
        case let .mode(name):
            guard settings.modes[name] != nil else { throw InvalidConfig(message: "there is no binding mode '\(name)'") }
            setMode(name)
        case let .triggerBinding(binding, mode):
            guard let script = settings.modes[mode]?[binding] else { throw InvalidConfig(message: "no binding '\(binding)' in mode '\(mode)'") }
            return (execute(script, window: window).ok, nil)
        case let .volume(volume):
            switch volume {
            case .up: handlers.mediaKey(.volumeUp)
            case .down: handlers.mediaKey(.volumeDown)
            case .muteToggle: handlers.mediaKey(.volumeMute)
            case .muteOn: exec(["/usr/bin/osascript", "-e", "set volume output muted true"])
            case .muteOff: exec(["/usr/bin/osascript", "-e", "set volume output muted false"])
            case let .set(level): exec(["/usr/bin/osascript", "-e", "set volume output volume \(level)"])
            }
        case let .scratchpad(bundleID, new):
            try scratchpad(bundleID, new: new)
        case let .ignoreMonitor(on, patterns):
            try ignoreMonitors(patterns, on)
        case let .monitorSetting(setting, patterns):
            for id in try settingMonitors(patterns) { system.setMonitor(id, setting) }
        case let .moveMouse(position, failIfNoop):
            return (moveMouse(position) || !failIfNoop, nil)
        case let .list(query):
            return (true, list(query))
        case let .test(lhs, op, rhs, negate):
            let subject = window ?? model.focused
            let left = interpolate(lhs, window: subject), right = interpolate(rhs, window: subject)
            let result = switch op {
            case .equals: left == right
            case .matches: left.range(of: right, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return (result != negate, nil)
        case let .result(value):
            return (value, nil)
        case let .echo(text):
            return (true, interpolate(text, window: window ?? model.focused))
        default:
            let (ok, effect) = try model.run(command, window: window)
            perform(effect)
            return (ok, nil)
        }
        return (true, nil)
    }

    private func perform(_ effect: WMEffect) {
        switch effect {
        case .none:
            break
        case let .close(ids, quitIfLastWindow):
            for id in ids {
                guard let app = records[id]?.app else { continue }
                if quitIfLastWindow, records.values.filter({ $0.app.pid == app.pid }).count == 1 {
                    app.terminate()
                } else {
                    app.close(id)
                }
            }
        case let .minimize(id):
            records[id]?.app.minimize(id)
        case let .nativeFullscreen(id, on):
            records[id]?.app.setFullscreen(id, on)
        }
    }

    /// After commands: apply the layout, sync macOS focus, fire the focus callbacks.
    private func afterCommands(since before: FocusState) {
        guard let model else { return }
        apply()
        let workspace = model.focusedWorkspace.name
        if model.focused != before.window || workspace != before.workspace {
            if let left = before.window, left != model.focused { leftByCommand = (left, .now) }
            focusNative()
        }
        focusChanged(since: before)
        announce()
    }

    func focusChanged(since before: FocusState) {
        guard let model, !inCallback else { return }
        inCallback = true
        defer { inCallback = false }
        let workspace = model.focusedWorkspace.name
        if model.focused != before.window || workspace != before.workspace, let script = settings.onFocusChanged {
            _ = execute(script, window: model.focused)
        }
        if model.focusedMonitor != before.monitor, let script = settings.onFocusedMonitorChanged {
            _ = execute(script, window: model.focused)
        }
        if workspace != before.workspace, !settings.execOnWorkspaceChange.isEmpty {
            exec(settings.execOnWorkspaceChange, extra: ["AEROSPACE_FOCUSED_WORKSPACE": workspace, "AEROSPACE_PREV_WORKSPACE": before.workspace])
        }
    }

    func setMode(_ name: String) {
        guard name != mode else { return }
        mode = name
        handlers.modeChanged(name)
        if !inCallback, let script = settings.onModeChanged {
            inCallback = true
            _ = execute(script, window: nil)
            inCallback = false
        }
    }

    private func exec(_ argv: [String], extra: [String: String] = [:]) {
        HyperSpace.launch(argv, environment: extra)
    }
}
