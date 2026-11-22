import Foundation
import Testing
@testable import HyperSpace

/// Both run their work on the main queue: a block queued after theirs runs after it.
@Suite @MainActor struct SchedulingTests {
    /// Waits until the main queue has run what was queued before, plus `delay` seconds.
    private func drainMain(after delay: TimeInterval = 0) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { continuation.resume() }
        }
    }

    @Test func coalescerRunsTheFirstWorkOncePerBurst() async {
        let coalescer = Coalescer()
        var runs: [Int] = []
        coalescer.schedule { runs.append(1) }
        coalescer.schedule { runs.append(2) }
        #expect(runs.isEmpty)
        await drainMain()
        #expect(runs == [1])
        coalescer.schedule { runs.append(3) }
        await drainMain()
        #expect(runs == [1, 3])
    }

    @Test func aCoalescerWithADelayWaitsForIt() async {
        let coalescer = Coalescer(delay: 0.01)
        var runs: [Int] = []
        coalescer.schedule { runs.append(1) }
        coalescer.schedule { runs.append(2) }
        await waitUntil { !runs.isEmpty }
        #expect(runs == [1])
    }

    @Test func debouncerRunsTheLastWork() async {
        let debouncer = Debouncer(delay: 0.01)
        var runs: [Int] = []
        debouncer.schedule { runs.append(1) }
        debouncer.schedule { runs.append(2) }
        #expect(debouncer.isPending)
        await waitUntil { !debouncer.isPending }
        #expect(runs == [2])
        #expect(!debouncer.isPending)
    }

    @Test func aCancelledDebouncerRunsNothing() async {
        let debouncer = Debouncer(delay: 0.01)
        var runs = 0
        debouncer.schedule { runs += 1 }
        debouncer.cancel()
        #expect(!debouncer.isPending)
        // Ten times the delay: had it not been cancelled, it would have run by then.
        await drainMain(after: 0.1)
        #expect(runs == 0)
    }
}
