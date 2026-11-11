import AppKit

/// The report to paste when something goes wrong, and the notes it carries.
extension WindowManager {
    // MARK: - Debug report

    /// Keeps a problem for the debug report (and logs it).
    func note(_ issue: String) {
        log.debug("\(issue, privacy: .public)")
        let time = Date().formatted(date: .omitted, time: .standard)
        issues.append("\(time) \(issue)")
        if issues.count > 30 { issues.removeFirst(issues.count - 30) }
    }

    /// What the window manager knows, to paste when something goes wrong. Titles are the
    /// cached ones: no AX round trip on the main thread.
    func debugReport() -> String {
        scopedValue {
            var lines: [String] = []
            lines.append("Tiling: \(running ? "running" : "stopped"), enabled \(config.enabled), layout \(config.layout.rawValue)")
            let screens = currentScreens()
            let focusedID = focusedScreen()?.id
            for (i, screen) in screens.enumerated() {
                let shown = displayed[screen.id].map { "\(name(of: $0)) (#\($0 + 1))" } ?? "none"
                lines.append("Display \(i + 1): id \(screen.id) \(screen.uuid) \(Self.describe(screen.frame)) visible \(Self.describe(screen.visible)) shows \(shown)\(screen.id == focusedID ? " [focused]" : "")")
            }
            if !homeOverride.isEmpty {
                lines.append("Moved workspaces: " + homeOverride.sorted { $0.key < $1.key }.map { "\(name(of: $0.key)) → display \($0.value)" }.joined(separator: ", "))
            }
            if !config.pins.isEmpty {
                lines.append("Pinned workspaces: " + config.pins.sorted { $0.key < $1.key }.map { workspace, pin in
                    "\(name(of: workspace)) → \(pin) (\(pinnedDisplay(of: workspace, screens).map { "display \($0.id)" } ?? "not connected"))"
                }.joined(separator: ", "))
            }
            if !DisplayMonitor.absent.isEmpty {
                lines.append("Displays left out (asleep or on another input): " + DisplayMonitor.absent.sorted().map(String.init).joined(separator: ", "))
            }
            let bounds = currentBounds()
            let byWorkspace = Dictionary(grouping: orderedWindows, by: \.workspace)
            for workspace in 0..<workspaceCount {
                let members = byWorkspace[workspace] ?? []
                guard !members.isEmpty else { continue }
                lines.append("Workspace \(name(of: workspace)) (#\(workspace + 1)):")
                for window in members {
                    let title = (window.title ?? "").prefix(40)
                    var flags: [String] = []
                    if window.isFloating { flags.append(window.isDialog ? "floating (dialog)" : "floating") }
                    if window.scratchpad { flags.append(window.scratchpadShown ? "scratchpad shown" : "scratchpad") }
                    if window.hiddenFrame != nil { flags.append("parked") }
                    if bounds[window.id] == nil { flags.append("off screen") }
                    lines.append("  \(window.appLabel) #\(window.id) “\(title)” \(bounds[window.id].map(Self.describe) ?? "-") \(flags.joined(separator: " "))")
                }
            }
            lines.append("Watched apps: " + apps.values.map { $0.bundleID ?? "\($0.pid)" }.sorted().joined(separator: ", "))
            lines.append("Recent issues:" + (issues.isEmpty ? " none" : ""))
            lines += issues.map { "  " + $0 }
            return lines.joined(separator: "\n")
        }
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height)))"
    }
}
