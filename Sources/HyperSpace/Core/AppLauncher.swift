import AppKit

/// Finds and opens apps named by bundle identifier ("com.apple.Terminal") or name ("Terminal").
enum AppLauncher {
    /// Names already resolved to a bundle identifier (main thread only): shortcuts such as
    /// `scratchpad <App>` ask on every press. Dropped when the app is no longer found.
    private static var bundleIDs: [String: String] = [:]

    private static func installedURL(forBundleID id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    private static func urlInFolders(named name: String) -> URL? {
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.lazy
            .map { URL(fileURLWithPath: "\($0)/\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func url(for name: String) -> URL? {
        installedURL(forBundleID: name) ?? urlInFolders(named: name)
    }

    static func bundleID(for name: String) -> String? {
        if let known = bundleIDs[name] { return known }
        let resolved: String?
        if installedURL(forBundleID: name) != nil {
            resolved = name
        } else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            resolved = running.bundleIdentifier
        } else {
            resolved = urlInFolders(named: name).flatMap { Bundle(url: $0)?.bundleIdentifier }
        }
        if let resolved { bundleIDs[name] = resolved }
        return resolved
    }

    /// Opens (or brings forward, asking a running app with no window for a new one) the app.
    static func open(_ name: String) {
        guard let url = url(for: name) else {
            bundleIDs[name] = nil
            log.error("launch: app not found: \(name, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
