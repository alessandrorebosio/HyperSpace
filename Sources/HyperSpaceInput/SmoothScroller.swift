import CoreGraphics
import Foundation

/// Turns wheel notches into a short glide of trackpad-like scroll events, like a trackpad or
/// a free-spinning wheel. Each notch adds distance; a 120 Hz timer sends a fifth of what is
/// left on every tick, so motion eases out and quick notches add up to a faster glide.
/// Input thread only: the timer runs on the input thread's run loop.
struct SmoothScroller {
    /// Points of travel per wheel line.
    static let pointsPerLine = 12.0
    private static let tick = 1.0 / 120
    /// Share of the remaining distance sent per tick.
    private static let step = 0.2

    private final class State {
        var remainingX = 0.0
        var remainingY = 0.0
        var timer: CFRunLoopTimer?
    }

    private let state = State()

    func add(dx: Double, dy: Double) {
        // A change of direction drops the rest of the old glide.
        if dy != 0, state.remainingY.sign != dy.sign { state.remainingY = 0 }
        if dx != 0, state.remainingX.sign != dx.sign { state.remainingX = 0 }
        state.remainingX += dx
        state.remainingY += dy
        guard state.timer == nil else { return }
        let state = self.state
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), Self.tick, 0, 0) { timer in
            let x = Self.take(&state.remainingX), y = Self.take(&state.remainingY)
            if x != 0 || y != 0 { Post.smoothScroll(dx: x, dy: y) }
            if state.remainingX == 0, state.remainingY == 0 {
                CFRunLoopTimerInvalidate(timer)
                state.timer = nil
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        state.timer = timer
    }

    func stop() {
        if let timer = state.timer { CFRunLoopTimerInvalidate(timer) }
        state.timer = nil
        state.remainingX = 0
        state.remainingY = 0
    }

    /// Whole points to send this tick; the fraction stays for the next ones.
    private static func take(_ remaining: inout Double) -> Int32 {
        guard abs(remaining) >= 0.5 else {
            remaining = 0
            return 0
        }
        var amount = (remaining * step).rounded()
        if amount == 0 { amount = remaining.sign == .minus ? -1 : 1 }
        remaining -= amount
        return Int32(amount)
    }
}
