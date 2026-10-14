import Foundation
import HyperSpaceCore

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
}
