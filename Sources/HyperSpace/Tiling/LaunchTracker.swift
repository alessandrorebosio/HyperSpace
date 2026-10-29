import Foundation

/// Remembers the workspace each app was opened from, so the windows it shows while
/// still loading join that workspace even if you have switched to another one meanwhile.
struct LaunchTracker {
    /// How long a launch may take before its first window.
    static let launchTimeout: TimeInterval = 60
    /// After the first window, how long further windows (an app opening several) still follow it.
    static let grace: TimeInterval = 3

    private var launches: [pid_t: (workspace: Int, until: Date)] = [:]

    mutating func launched(_ pid: pid_t, in workspace: Int, at now: Date = Date()) {
        launches[pid] = (workspace, now.addingTimeInterval(Self.launchTimeout))
    }

    /// The workspace a new window of `pid` belongs to, if the app is still opening.
    mutating func workspace(for pid: pid_t, at now: Date = Date()) -> Int? {
        guard let launch = launches[pid] else { return nil }
        guard now < launch.until else {
            launches[pid] = nil
            return nil
        }
        launches[pid] = (launch.workspace, min(launch.until, now.addingTimeInterval(Self.grace)))
        return launch.workspace
    }

    func contains(_ pid: pid_t) -> Bool {
        launches[pid] != nil
    }

        mutating func forget(_ pid: pid_t) {
        launches[pid] = nil
    }

    mutating func removeAll() {
        launches.removeAll()
    }
}
