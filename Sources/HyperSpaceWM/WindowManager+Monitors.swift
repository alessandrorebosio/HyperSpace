import Foundation
import HyperSpaceCore

/// Displays the window manager leaves out though macOS still has them: the ones
/// `ignore-monitor` took out, and, with `detect-monitor-input`, the ones showing another
/// input (a display switched to another computer often stays connected). Left out, a display
/// is as if disconnected: its workspaces wait on the others, and come back with it. Displays
/// are told apart by `key` (EDID UUID), so two identical ones aren't confused.
extension WindowManager {
    /// Every display macOS has, for the menu, and whether it's left out.
    public var displays: [(key: String, name: String, ignored: Bool)] {
        system.monitors().map { ($0.key, $0.name, isIgnored($0.key)) }
    }

    /// The displays the model gets: every display, but never none.
    func shownMonitors(_ all: [WMMonitor]? = nil) -> [WMMonitor] {
        let all = all ?? system.monitors()
        let shown = all.filter { !isIgnored($0.key) }
        return shown.isEmpty ? all : shown
    }

    func isIgnored(_ key: String) -> Bool {
        if ignoredMonitors.contains(key) { return true }
        guard settings.detectMonitorInput, let input = monitorInputs[key], let mac = macInputs[key] else { return false }
        return input != mac
    }

    /// `ignore-monitor`, by monitor pattern.
    func ignoreMonitors(_ patterns: [String], _ on: Bool?) throws(InvalidConfig) {
        let all = system.monitors()
        let matched = all.filter { monitor in patterns.contains { WMMonitor.matches($0, monitor, in: all) } }
        guard !matched.isEmpty else { throw InvalidConfig(message: "ignore-monitor: no monitor matches '\(patterns.joined(separator: " "))'") }
        try setIgnored(matched.map(\.key), on)
    }

    /// Leaves the displays out, or takes them back (nil toggles each). Taking a display back
    /// while it shows another input makes that input the Mac's: the way to correct one
    /// learned wrong.
    public func setIgnored(_ keys: [String], _ on: Bool?) throws(InvalidConfig) {
        let before = ignoredMonitors
        for key in keys {
            if on ?? !isIgnored(key) {
                ignoredMonitors.insert(key)
            } else {
                ignoredMonitors.remove(key)
                if let input = monitorInputs[key], macInputs[key] != input { learn(input, for: key) }
            }
        }
        guard system.monitors().contains(where: { !isIgnored($0.key) }) else {
            ignoredMonitors = before
            throw InvalidConfig(message: "ignore-monitor: every monitor would be left out")
        }
        monitorsChanged()
    }

    // MARK: - detect-monitor-input

    /// Reads every display's input now and every 2 s.
    func pollMonitorInputs(_ on: Bool) {
        guard on != (inputPolling != nil) else { return }
        inputPolling?.cancel()
        inputPolling = nil
        monitorInputs = [:]
        guard on else { return }
        inputPolling = Task { [weak self] in
            while !Task.isCancelled {
                self?.readMonitorInputs()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func readMonitorInputs() {
        let monitors = system.monitors()
        // A lone display is never left out: nothing to read.
        guard monitors.count > 1 else { return }
        system.monitorInputs(monitors.map(\.id)) { [weak self] inputs in
            guard let self, self.inputPolling != nil else { return }
            self.inputsRead(inputs)
        }
    }

    /// The Mac's input on a display is learned only when it surely shows the Mac: it was
    /// just plugged in, or the person focused a window on it. A display seen for the first
    /// time at launch may be showing another computer.
    func displaysConnected() {
        let keys = Set(system.monitors().map(\.key))
        if !isStartingUp { learnable.formUnion(keys.subtracting(connectedMonitors)) }
        connectedMonitors = keys
    }

    /// The person focused a window: the display it's on shows the Mac.
    func focusedByUser() {
        guard inputPolling != nil, !isStartingUp, let model,
              let monitor = model.monitors.first(where: { $0.id == model.focusedMonitor }), macInputs[monitor.key] == nil else { return }
        learnable.insert(monitor.key)
    }

    /// A display that doesn't answer keeps the input it was last read showing: a missed
    /// read doesn't take it out or bring it back.
    private func inputsRead(_ inputs: [UInt32: UInt8]) {
        guard let model else { return }
        let monitors = system.monitors()
        monitorInputs = monitorInputs.filter { key in monitors.contains { $0.key == key.key } }
        for monitor in monitors {
            guard let input = inputs[monitor.id] else { continue }
            monitorInputs[monitor.key] = input
            // Learned under its name by 0.5.0.
            if macInputs[monitor.key] == nil, let old = macInputs.removeValue(forKey: monitor.name) { learn(old, for: monitor.key) }
            if macInputs[monitor.key] == nil, learnable.contains(monitor.key) { learn(input, for: monitor.key) }
            learnable.remove(monitor.key)
        }
        let shown = shownMonitors(monitors)
        guard Set(shown.map(\.id)) != Set(model.monitors.map(\.id)) else { return }
        let left = monitors.filter { isIgnored($0.key) }.map(\.name)
        log.info("displays shown: \(shown.map(\.name)), on another input: \(left)")
        monitorsChanged()
    }

    private func learn(_ input: UInt8, for key: String) {
        macInputs[key] = input
        saveMacInputs()
    }
}
