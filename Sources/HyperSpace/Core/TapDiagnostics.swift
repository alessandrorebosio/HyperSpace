import Foundation

/// What the event tap has seen and the state it is in, for the debug report: when shortcuts
/// stop working, it tells whether keys still arrive, whether the combination key (caps lock)
/// does, and whether the bindings are suspended. Counts and times only: no key is recorded.
struct TapDiagnostics: Equatable {
    /// A count and when it last went up (uptime nanoseconds, 0: never).
    struct Tally: Equatable {
        var count = 0
        var last: UInt64 = 0

        mutating func add(at now: UInt64) {
            count += 1
            last = now
        }

        /// "12 (last 3 s ago)", "0".
        func text(now: UInt64) -> String {
            guard count > 0 else { return "0" }
            let seconds = now > last ? (now - last) / 1_000_000_000 : 0
            let ago = seconds < 120 ? "\(seconds) s" : seconds < 7200 ? "\(seconds / 60) min" : "\(seconds / 3600) h"
            return "\(count) (last \(ago) ago)"
        }
    }

    /// Key presses (autorepeat left out), whatever they did.
    var keys = Tally()
    /// A combination key (caps lock → ⌃⌥⇧) went down or up.
    var combinationKeys = Tally()
    /// Presses that ran a shortcut.
    var shortcuts = Tally()
    /// Presses with a combination held that no shortcut answered.
    var unbound = Tally()
    /// The system switched the tap off (it took too long, or by user input); it is switched back on.
    var disabled = Tally()

    // Filled when the report is asked for.
    var installed = false
    var enabled = false
    var keyBindingsSuspended = false
    var buttonsSuspended = false
    var held: Modifiers = []
    var carriers = 0
    var actions = 0

    func lines(now: UInt64) -> [String] {
        let tap = !installed ? "not installed" : enabled ? "enabled" : "disabled by the system"
        return [
            "Event tap state: \(tap); key bindings \(keyBindingsSuspended ? "suspended (Settings is recording)" : "active")"
                + "; mouse buttons \(buttonsSuspended ? "suspended" : "active")"
                + "; combination held: \(held.isEmpty ? "none" : held.symbols)"
                + "; \(carriers) combination key(s), \(actions) action(s)",
            "Event tap seen: key presses \(keys.text(now: now))"
                + "; combination key events \(combinationKeys.text(now: now))"
                + "; shortcuts run \(shortcuts.text(now: now))"
                + "; presses with a combination and no shortcut \(unbound.text(now: now))"
                + "; switched off by the system \(disabled.text(now: now))",
        ]
    }

    /// When the tap thread does not answer.
    static let noAnswer = "Event tap state: its thread did not answer (busy or stuck)"
}
