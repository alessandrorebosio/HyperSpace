import Foundation

/// Runs AX writes (move, resize, focus) off the main thread, on one serial queue per app.
///
/// A write waits for the app to answer, up to the AX timeout: an app that is busy or hung
/// would otherwise hold up every shortcut. Per app the writes stay in order; different apps
/// no longer wait for each other. Reads stay on the main thread, which owns all state.
final class AXWriter {
    private var queues: [pid_t: DispatchQueue] = [:]

    /// Main thread only.
    func perform(_ pid: pid_t, _ block: @escaping () -> Void) {
        queue(for: pid).async(execute: block)
    }

    func forget(_ pid: pid_t) {
        queues[pid] = nil
    }

    /// Waits for the pending writes (on quit, so parked windows really come back).
    func flush(timeout: TimeInterval) {
        let group = DispatchGroup()
        for queue in queues.values { queue.async(group: group) {} }
        _ = group.wait(timeout: .now() + timeout)
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let queue = queues[pid] { return queue }
        let queue = DispatchQueue(label: "HyperSpace.AX.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        return queue
    }
}
