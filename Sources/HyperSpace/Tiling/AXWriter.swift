import Foundation

/// Runs AX calls off the main thread, on one serial queue per app: writes (move, resize,
/// focus) and the batches of reads that tracking a window needs.
///
/// A call waits for the app to answer, up to the AX timeout: an app that is busy or hung
/// would otherwise hold up every shortcut. Per app the calls stay in order; different apps
/// no longer wait for each other. State stays on the main thread: reads hand their result back there.
final class AXWriter {
    private var queues: [pid_t: DispatchQueue] = [:]

    /// Main thread only.
    func perform(_ pid: pid_t, _ block: @escaping () -> Void) {
        queue(for: pid).async(execute: block)
    }

    /// Runs `work(false)` on the app's queue; when it returns true it runs again, `work(true)`,
    /// `delay` seconds later. The queue is free in between (a wait would hold up every call
    /// to a slow app). Main thread only.
    func perform(_ pid: pid_t, retryAfter delay: TimeInterval, _ work: @escaping (_ isRetry: Bool) -> Bool) {
        let serial = queue(for: pid)
        serial.async {
            guard work(false) else { return }
            serial.asyncAfter(deadline: .now() + delay) { _ = work(true) }
        }
    }

    /// Runs `work` on the app's queue and hands its result to `then` on the main thread.
    func read<T>(_ pid: pid_t, _ work: @escaping () -> T, then: @escaping (T) -> Void) {
        queue(for: pid).async {
            let value = work()
            DispatchQueue.main.async { then(value) }
        }
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
