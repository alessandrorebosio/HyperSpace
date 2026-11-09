import AppKit

/// What the menu bar shows instead of its icon: the workspace on each display, left to
/// right, and the index of the focused display.
struct WorkspaceBar: Equatable {
    let names: [String]
    let focused: Int
}

/// What the menu bar shows for a workspace.
struct WorkspaceSummary {
    struct Window {
        let app: String
        let title: String?
        let icon: NSImage?
    }

    /// An app of the workspace, with how many of its windows are there.
    struct App: Identifiable {
        let name: String
        let icon: NSImage?
        let windows: Int
        var id: String { name }
    }

    let index: Int
    let name: String
    /// 1-based display (left to right) showing it, if any.
    let display: Int?
    let windows: [Window]

    /// One entry per app, in the order of its first window (the menu and the overview list apps).
    var apps: [App] {
        var counts: [String: Int] = [:]
        var first: [Window] = []
        for window in windows {
            if counts[window.app] == nil { first.append(window) }
            counts[window.app, default: 0] += 1
        }
        return first.map { App(name: $0.app, icon: $0.icon, windows: counts[$0.app] ?? 1) }
    }
}
