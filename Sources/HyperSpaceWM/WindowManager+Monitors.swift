import Foundation
import HyperSpaceCore

/// Displays the window manager leaves out though macOS still has them: the ones
/// `ignore-monitor` took out, and, with `detect-monitor-input`, the ones showing another
/// input (a display switched to another computer often stays connected). Left out, a display
/// is as if disconnected: its workspaces wait on the others, and come back with it.
extension WindowManager {
    /// The displays the model gets: every display, but never none.
    func shownMonitors(_ all: [WMMonitor]? = nil) -> [WMMonitor] {
        let all = all ?? system.monitors()
        let shown = all.filter { !isIgnored($0.name) }
        return shown.isEmpty ? all : shown
    }

    func isIgnored(_ name: String) -> Bool {
        if ignoredMonitors.contains(name) { return true }
        guard settings.detectMonitorInput, let input = monitorInputs[name], let mac = macInputs[name] else { return false }
        return input != mac
    }

    /// `ignore-monitor`. Taking a display back while it shows another input makes that
    /// input the Mac's: the way to correct the one first read.
    func ignoreMonitors(_ patterns: [String], _ on: Bool?) throws(InvalidConfig) {
        let all = system.monitors()
        let matched = all.filter { monitor in patterns.contains { WMMonitor.matches($0, monitor, in: all) } }
        guard !matched.isEmpty else { throw InvalidConfig(message: "ignore-monitor: no monitor matches '\(patterns.joined(separator: " "))'") }
        let before = ignoredMonitors
        for monitor in matched {
            if on ?? !isIgnored(monitor.name) {
                ignoredMonitors.insert(monitor.name)
            } else {
                ignoredMonitors.remove(monitor.name)
                if let input = monitorInputs[monitor.name], macInputs[monitor.name] != input {
                    macInputs[monitor.name] = input
                    saveMacInputs()
                }
            }
        }
        guard all.contains(where: { !isIgnored($0.name) }) else {
            ignoredMonitors = before
            throw InvalidConfig(message: "ignore-monitor: every monitor would be left out")
        }
        monitorsChanged()
    }

    /// `detect-monitor-input`: reads every display's input now and every 2 s.
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

    /// A display that doesn't answer keeps the input it was last read showing: a missed
    /// read doesn't take it out or bring it back.
    private func inputsRead(_ inputs: [UInt32: UInt8]) {
        guard let model else { return }
        let monitors = system.monitors()
        monitorInputs = monitorInputs.filter { name in monitors.contains { $0.name == name.key } }
        for monitor in monitors {
            guard let input = inputs[monitor.id] else { continue }
            monitorInputs[monitor.name] = input
            if macInputs[monitor.name] == nil {
                macInputs[monitor.name] = input
                saveMacInputs()
            }
        }
        let shown = shownMonitors(monitors)
        guard Set(shown.map(\.id)) != Set(model.monitors.map(\.id)) else { return }
        let left = monitors.filter { isIgnored($0.name) }.map(\.name)
        log.info("displays shown: \(shown.map(\.name)), on another input: \(left)")
        monitorsChanged()
    }
}
