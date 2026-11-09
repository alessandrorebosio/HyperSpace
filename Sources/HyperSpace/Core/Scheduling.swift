import Foundation

extension DispatchQueue {
    /// Runs `work` once after each of `delays` (seconds), for things that settle a moment later.
    func asyncAfter(delays: [TimeInterval], execute work: @escaping () -> Void) {
        for delay in delays { asyncAfter(deadline: .now() + delay, execute: work) }
    }
}

/// Runs the work scheduled last once `delay` seconds pass with nothing newer scheduled: a burst
/// of requests (editor saves, keystrokes) becomes one run. Main thread only.
final class Debouncer {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Whether work is waiting to run.
    var isPending: Bool { pending != nil }

    func schedule(_ work: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            work()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Runs work at most once per request burst: requests made while a run is pending join it
/// (the first one's work runs, after `delay`, or on the next turn of the run loop when nil).
/// Main thread only.
final class Coalescer {
    private let delay: TimeInterval?
    private var scheduled = false

    init(delay: TimeInterval? = nil) {
        self.delay = delay
    }

    func schedule(_ work: @escaping () -> Void) {
        guard !scheduled else { return }
        scheduled = true
        let run = { [weak self] in
            guard let self else { return }
            scheduled = false
            work()
        }
        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: run)
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }
}
