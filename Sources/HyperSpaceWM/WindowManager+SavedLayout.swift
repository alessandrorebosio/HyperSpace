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
        apply()
        handlers.changed()
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

    private func identity(_ app: WindowApp, _ record: WindowRecord) -> WMSnapshot.Identity {
        WMSnapshot.Identity(app: app.bundleID, title: record.title)
    }
}
