import Foundation
import os

public enum HyperSpace {
    public static let version = "0.2.0"
    public static let bundleID = "com.alessandrorebosio.HyperSpace"
    /// The latest release, as GitHub's API describes it (for "Check for Updates").
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/alessandrorebosio/HyperSpace/releases/latest")!

    /// Whether release `tag` (`v0.2.0` or `0.2.0`) is a later version than `version`,
    /// comparing numbers part by part (`0.10.0` is later than `0.9.1`).
    public static func isNewer(_ tag: String, than version: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.drop { $0 == "v" }.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let new = parts(tag), old = parts(version)
        for i in 0..<max(new.count, old.count) {
            let a = i < new.count ? new[i] : 0, b = i < old.count ? old[i] : 0
            if a != b { return a > b }
        }
        return false
    }

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
