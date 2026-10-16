import Foundation
import HyperSpaceCore

/// The layout kept across restarts: written when the window manager stops, put back once
/// every app's windows are read at startup.
extension WindowManager {
    func loadLayout() -> WMSnapshot? {
        (try? Data(contentsOf: system.layoutURL)).flatMap { try? JSONDecoder().decode(WMSnapshot.self, from: $0) }
    }

    /// Startup is over: every app present at launch has reported its windows.
    func startedUp() {
        isStartingUp = false
        guard let model, let saved = savedLayout else { return }
        savedLayout = nil
        model.restore(saved, map: saved.match(records.mapValues { identity($0.app, $0.record) }))
        // Tiled for a moment while apps were read: shown scratchpads are centered again.
        for window in model.scratchpadHomes.keys { center(window) }
        apply()
        announce()
    }

    /// Written once, when the window manager stops (quit, `kill`, disable).
    func saveLayout(_ model: WMModel) {
        let snapshot = model.snapshot { id in
            records[id].map { identity($0.app, $0.record) } ?? WMSnapshot.Identity(app: nil, title: "")
        }
        do {
            try FileManager.default.createDirectory(at: system.layoutURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: system.layoutURL, options: .atomic)
        } catch {
            log.error("saving the layout failed: \(error)")
        }
    }

    /// Writes off the main thread, in order.
    private static let disk = DispatchQueue(label: "hyperspace.wm.disk", qos: .utility)

    private var appWorkspacesURL: URL {
        system.layoutURL.deletingLastPathComponent().appending(path: "app-workspaces.json")
    }

    func loadAppWorkspaces() -> [String: String] {
        Self.disk.sync {} // a write still pending
        return (try? Data(contentsOf: appWorkspacesURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// Written whenever it changes (an app quitting is rare), without holding up the main thread.
    func saveAppWorkspaces() {
        guard let data = try? JSONEncoder().encode(appWorkspaces) else { return }
        let url = appWorkspacesURL, log = log
        Self.disk.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("saving the apps' workspaces failed: \(error)")
            }
        }
    }

    private func identity(_ app: WindowApp, _ record: WindowRecord) -> WMSnapshot.Identity {
        WMSnapshot.Identity(app: app.bundleID, title: record.title)
    }
}
