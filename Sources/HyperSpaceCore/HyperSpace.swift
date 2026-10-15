import Foundation
import os

public enum HyperSpace {
    public static let version = "0.1.1"
    public static let bundleID = "com.alessandrorebosio.HyperSpace"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: bundleID, category: category)
    }

    /// HyperSpace's environment with Homebrew on the PATH: apps launched from Finder get a
    /// minimal one. Built once.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return environment
    }()

    /// Starts a program without waiting for it, off the calling thread (fork and exec take
    /// milliseconds). Its output is discarded.
    public static func launch(_ argv: [String], environment extra: [String: String] = [:]) {
        guard let path = argv.first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = Array(argv.dropFirst())
            process.environment = extra.isEmpty ? environment : environment.merging(extra) { $1 }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { logger("exec").error("\(path) failed to start: \(error)") }
        }
    }
}
