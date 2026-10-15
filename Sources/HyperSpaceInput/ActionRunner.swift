import AppKit
import HyperSpaceCore

/// Outputs that leave the input thread: shell commands and apps.
enum ActionRunner {
    private static let log = HyperSpace.logger("action")

    /// Runs a shell command without waiting for it. Homebrew paths are added because apps
    /// launched from Finder get a minimal PATH.
    static func shell(_ command: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                log.error("shell action failed: \(error)")
            }
        }
    }

    /// Opens an app, or brings it to the front if it's running. No shell involved.
    /// - Parameter app: a bundle id (`com.apple.Safari`) or an app name (`Safari`).
    @MainActor
    static func open(app: String) {
        guard let url = url(of: app) else {
            log.error("app '\(app)' not found")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("cannot open \(app): \(error.localizedDescription)") }
        }
    }

    @MainActor private static var urls: [String: URL] = [:]

    @MainActor
    private static func url(of app: String) -> URL? {
        if let url = urls[app], FileManager.default.fileExists(atPath: url.path) { return url }
        let workspace = NSWorkspace.shared
        let name = app.hasSuffix(".app") ? app : app + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices"]
        let url = workspace.urlForApplication(withBundleIdentifier: app)
            ?? folders.lazy.map { URL(fileURLWithPath: $0).appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
        urls[app] = url
        return url
    }
}
