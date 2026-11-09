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

    private static func url(for name: String) -> URL? {
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

    // MARK: - For the settings pages (main thread)

    /// The regular apps running, by name. The pages ask on every redraw (a keystroke in a
    /// text field), so the list is kept until an app launches or quits.
    static var runningApps: [(name: String, bundleID: String)] {
        if let cached = cachedApps { return cached }
        watchRunningApps()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        cachedApps = apps
        return apps
    }

    private static var cachedApps: [(name: String, bundleID: String)]?
    private static var appObservers: [NSObjectProtocol] = []

    private static func watchRunningApps() {
        guard appObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                AppLauncher.cachedApps = nil
            })
        }
    }

    /// Names and icons by bundle id: rows ask on every redraw, LaunchServices is slow.
    private static var appInfo: [String: (name: String, icon: NSImage?)] = [:]

    private static func info(_ bundleID: String) -> (name: String, icon: NSImage?) {
        if let info = appInfo[bundleID] { return info }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let info = (name: url.map { displayName(at: $0) } ?? bundleID,
                    icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        appInfo[bundleID] = info
        return info
    }

    /// The name Finder shows for the app, less a trailing ".app" (shown when extensions are on).
    private static func displayName(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Forgets the names and icons (when the settings window closes): rebuilt on demand.
    static func forgetAppInfo() {
        appInfo.removeAll()
    }

    /// An installed app's name, or its bundle id when it is not installed.
    static func name(_ bundleID: String) -> String { info(bundleID).name }

    static func icon(_ bundleID: String) -> NSImage? { info(bundleID).icon }
}
