import AppKit

/// Finds and opens apps named by bundle identifier ("com.apple.Terminal") or name ("Terminal").
enum AppLauncher {
    static func url(for name: String) -> URL? {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? folders.lazy
                .map { URL(fileURLWithPath: "\($0)/\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func bundleID(for name: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) != nil { return name }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return running.bundleIdentifier
        }
        return url(for: name).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Opens (or brings forward, asking a running app with no window for a new one) the app.
    static func open(_ name: String) {
        guard let url = url(for: name) else {
            log.error("launch: app not found: \(name, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
