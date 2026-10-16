import Foundation
import HyperSpaceCore

/// `subscribe`, as AeroSpace's: events as JSON lines (`{"_event": "focus-changed", ...}`)
/// for status bars, sent through `onEvent` to the clients that asked for them.
extension WindowManager {
    public static let events = ["focus-changed", "focused-monitor-changed", "focused-workspace-changed", "mode-changed", "window-detected"]

    /// `subscribe [--no-send-initial] (--all|<event>...)`: the events asked for, and unless
    /// `--no-send-initial` the current state as their first lines.
    public func subscribe(_ words: [String]) throws(InvalidConfig) -> (events: [String], initial: String) {
        guard model != nil else { throw InvalidConfig(message: "the window manager is off (wm.toml is empty)") }
        var names = words.filter { !$0.hasPrefix("--") }
        let flags = Set(words.filter { $0.hasPrefix("--") })
        let usage = "subscribe: usage: subscribe [--no-send-initial] (--all|\(Self.events.joined(separator: "|"))...)"
        guard flags.isSubset(of: ["--all", "--no-send-initial"]) else { throw InvalidConfig(message: usage) }
        if flags.contains("--all") { names = Self.events }
        guard !names.isEmpty else { throw InvalidConfig(message: usage) }
        if let unknown = names.first(where: { !Self.events.contains($0) }) {
            throw InvalidConfig(message: unknown == "binding-triggered" ? "subscribe: binding-triggered isn't supported" : usage)
        }
        guard !flags.contains("--no-send-initial") else { return (names, "") }
        let initial = names.compactMap { name -> String? in
            switch name {
            case "focus-changed": json(name, focusFields())
            case "focused-monitor-changed": json(name, monitorFields())
            case "focused-workspace-changed": json(name, ["workspace": focusedWorkspace ?? "", "prevWorkspace": focusedWorkspace ?? ""])
            case "mode-changed": json(name, ["mode": mode])
            default: nil
            }
        }
        return (names, initial.joined(separator: "\n"))
    }

    /// The focus moved (`focusChanged`): its events.
    func publishFocus(since before: FocusState) {
        guard onEvent != nil, let model else { return }
        let workspace = model.focusedWorkspace.name
        if model.focused != before.window || workspace != before.workspace { publish("focus-changed", focusFields()) }
        if model.focusedMonitor != before.monitor { publish("focused-monitor-changed", monitorFields()) }
        if workspace != before.workspace { publish("focused-workspace-changed", ["workspace": workspace, "prevWorkspace": before.workspace]) }
    }

    func publishWindowDetected(_ id: WindowID) {
        guard onEvent != nil, let app = records[id]?.app else { return }
        publish("window-detected", ["windowId": id, "workspace": model?.workspace(of: id)?.name ?? "",
                                    "appBundleId": app.bundleID ?? "", "appName": app.name])
    }

    func publish(_ event: String, _ fields: [String: Any]) {
        guard let onEvent, let line = json(event, fields) else { return }
        onEvent(event, line)
    }

    private func focusFields() -> [String: Any] {
        ["windowId": model?.focused.map { $0 as Any } ?? NSNull(), "workspace": focusedWorkspace ?? ""]
    }

    private func monitorFields() -> [String: Any] {
        guard let model else { return [:] }
        return ["workspace": model.focusedWorkspace.name,
                "monitorId": (model.monitors.firstIndex { $0.id == model.focusedMonitor } ?? 0) + 1]
    }

    private func json(_ event: String, _ fields: [String: Any]) -> String? {
        var object = fields
        object["_event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
