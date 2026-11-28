import Testing
@testable import HyperSpace

/// A TapState behind a reference, so `#expect` can call its mutating methods.
private final class Tap {
    var state = TapState()
    var config: TapConfig { state.config }
    var heldModifiers: Modifiers { state.heldModifiers }

    func key(code: Int, modifiers: Modifiers, down: Bool, isRepeat: Bool) -> TapState.Decision {
        state.key(code: code, modifiers: modifiers, down: down, isRepeat: isRepeat)
    }
    func button(_ button: Int, modifiers: Modifiers, down: Bool) -> TapState.Decision {
        state.button(button, modifiers: modifiers, down: down)
    }
    func setConfig(_ config: TapConfig) -> Bool { state.setConfig(config) }
    func resetKeys() -> Bool { state.resetKeys() }
    func setKeyBindingsSuspended(_ on: Bool) -> Bool { state.setKeyBindingsSuspended(on) }
    func setButtonsSuspended(_ on: Bool) { state.setButtonsSuspended(on) }
    func clearButtons() { state.clearButtons() }
}

/// The event tap's decisions about keys and buttons.
@Suite struct TapStateTests {
    private func state(_ json: String) throws -> Tap {
        let tap = Tap()
        _ = tap.setConfig(try config(json).tap)
        return tap
    }

    /// The key code of the carrier of a combination, by what it stands for.
    private func carrierCode(_ tap: Tap, _ modifiers: Modifiers) throws -> Int {
        try #require(tap.config.carrierTable.indices.first { code in
            let index = Int(tap.config.carrierTable[code])
            return index >= 0 && tap.config.carriers[index].modifiers == modifiers
        })
    }

    private func code(_ name: String) -> Int { Int(KeyCodes.lookup(name)!.keyCode!) }

    private let bindings = #"""
    { "keyboard": { "bindings": [
        { "keys": "cmd+alt+h", "action": "focus left" },
        { "keys": "cmd+alt+f", "action": "float" },
        { "keys": "cmd+alt+o", "action": "workspace-overview" }
    ] } }
    """#

    @Test func boundPressRunsAndItsKeyUpIsSwallowed() throws {
        let tap = try state(bindings)
        let h = code("h")
        #expect(tap.key(code: h, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.focus(.left)))
        // The key up comes without the modifiers if they went up first: still swallowed.
        #expect(tap.key(code: h, modifiers: [], down: false, isRepeat: false) == .swallow)
        #expect(tap.key(code: h, modifiers: [], down: false, isRepeat: false) == .pass)
    }

    @Test func unboundKeysPass() throws {
        let tap = try state(bindings)
        #expect(tap.key(code: code("h"), modifiers: [.cmd], down: true, isRepeat: false) == .pass)
        #expect(tap.key(code: code("j"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .pass)
        #expect(tap.key(code: 200, modifiers: [], down: true, isRepeat: false) == .pass)
    }

    @Test func autorepeatRunsOnlyStepwiseActions() throws {
        let tap = try state(bindings)
        #expect(tap.key(code: code("h"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.focus(.left)))
        #expect(tap.key(code: code("h"), modifiers: [.cmd, .alt], down: true, isRepeat: true) == .run(.focus(.left)))
        #expect(tap.key(code: code("f"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.toggleFloat))
        #expect(tap.key(code: code("f"), modifiers: [.cmd, .alt], down: true, isRepeat: true) == .swallow)
    }

    /// Releasing a modifier while the key is still held: its repeats stay with the binding.
    @Test func autorepeatKeepsItsBindingAfterAModifierIsReleased() throws {
        let tap = try state(#"""
        { "keyboard": { "bindings": [
            { "keys": "cmd+alt+h", "action": "focus left" },
            { "keys": "cmd+h", "action": "float" },
            { "keys": "cmd+alt+f", "action": "float" }
        ] } }
        """#)
        let h = code("h"), f = code("f")
        #expect(tap.key(code: h, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.focus(.left)))
        // ⌥ released: not "cmd+h", and not passed to the app as "hhhh".
        #expect(tap.key(code: h, modifiers: [.cmd], down: true, isRepeat: true) == .run(.focus(.left)))
        #expect(tap.key(code: h, modifiers: [], down: true, isRepeat: true) == .run(.focus(.left)))
        #expect(tap.key(code: h, modifiers: [], down: false, isRepeat: false) == .swallow)

        // An action that runs once keeps swallowing its repeats without modifiers too.
        #expect(tap.key(code: f, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.toggleFloat))
        #expect(tap.key(code: f, modifiers: [], down: true, isRepeat: true) == .swallow)
        #expect(tap.key(code: f, modifiers: [], down: false, isRepeat: false) == .swallow)
    }

    /// A key the app got keeps its repeats, even once modifiers make it a binding.
    @Test func autorepeatOfAKeyTheAppGotPasses() throws {
        let tap = try state(bindings)
        let h = code("h")
        #expect(tap.key(code: h, modifiers: [], down: true, isRepeat: false) == .pass)
        #expect(tap.key(code: h, modifiers: [.cmd, .alt], down: true, isRepeat: true) == .pass)
        #expect(tap.key(code: h, modifiers: [.cmd, .alt], down: false, isRepeat: false) == .pass)
    }

    /// A key-up that was missed: the next plain press of that key is the app's, and so its up.
    @Test func aNewUnboundPressForgetsAMissedKeyUp() throws {
        let tap = try state(bindings)
        let h = code("h")
        #expect(tap.key(code: h, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.focus(.left)))
        #expect(tap.key(code: h, modifiers: [], down: true, isRepeat: false) == .pass)
        #expect(tap.key(code: h, modifiers: [], down: false, isRepeat: false) == .pass)
    }

    @Test func overviewOpensWhileHeldAndClosesOnRelease() throws {
        let tap = try state(bindings)
        let o = code("o")
        #expect(tap.key(code: o, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .overview(true))
        #expect(tap.key(code: o, modifiers: [.cmd, .alt], down: true, isRepeat: true) == .swallow)
        #expect(tap.key(code: o, modifiers: [.cmd, .alt], down: false, isRepeat: false) == .overview(false))
    }

    @Test func forgettingTheKeysClosesTheOverview() throws {
        let tap = try state(bindings)
        _ = tap.key(code: code("o"), modifiers: [.cmd, .alt], down: true, isRepeat: false)
        #expect(tap.resetKeys())
        #expect(!tap.resetKeys())
        // Its key up is no longer swallowed.
        #expect(tap.key(code: code("o"), modifiers: [], down: false, isRepeat: false) == .pass)
    }

    @Test func suspendedBindingsPass() throws {
        let tap = try state(bindings)
        _ = tap.setKeyBindingsSuspended(true)
        #expect(tap.key(code: code("h"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .pass)
        _ = tap.setKeyBindingsSuspended(false)
        #expect(tap.key(code: code("h"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.focus(.left)))
    }

    @Test func modifierOnlyCarrierHoldsItsModifiers() throws {
        let tap = try state(#"{ "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] } }"#)
        let carrierCode = try #require(tap.config.carrierTable.firstIndex { $0 >= 0 })
        #expect(tap.key(code: carrierCode, modifiers: [], down: true, isRepeat: false) == .swallow)
        #expect(tap.heldModifiers == .meh)
        // Autorepeat of the carrier changes nothing.
        #expect(tap.key(code: carrierCode, modifiers: [], down: true, isRepeat: true) == .swallow)
        #expect(tap.heldModifiers == .meh)
        #expect(tap.key(code: carrierCode, modifiers: [], down: false, isRepeat: false) == .swallow)
        #expect(tap.heldModifiers.isEmpty)
    }

    @Test func comboCarrierPostsItsKey() throws {
        let tap = try state(#"{ "keyboard": { "remap": [ { "from": "caps_lock", "to": "cmd+space" } ] } }"#)
        let carrierCode = try #require(tap.config.carrierTable.firstIndex { $0 >= 0 })
        let space = UInt16(code("space"))
        #expect(tap.key(code: carrierCode, modifiers: [.shift], down: true, isRepeat: false)
                == .postKey(keyCode: space, modifiers: [.cmd, .shift], down: true))
        #expect(tap.key(code: carrierCode, modifiers: [], down: false, isRepeat: false)
                == .postKey(keyCode: space, modifiers: .cmd, down: false))
    }

    @Test func buttonsRunAndSwallowTheirRelease() throws {
        let tap = try state(#"{ "mouse": { "buttons": [ { "button": 3, "action": "navigate back" } ] } }"#)
        #expect(tap.button(3, modifiers: [], down: true) == .run(.navigate(back: true)))
        #expect(tap.button(3, modifiers: [], down: false) == .swallow)
        #expect(tap.button(4, modifiers: [], down: true) == .pass)
        tap.setButtonsSuspended(true)
        #expect(tap.button(3, modifiers: [], down: true) == .pass)
    }

    @Test func aNewConfigForgetsWhatWasHeld() throws {
        let tap = try state(bindings)
        _ = tap.key(code: code("o"), modifiers: [.cmd, .alt], down: true, isRepeat: false)
        #expect(tap.setConfig(try config(bindings).tap))
        #expect(tap.key(code: code("o"), modifiers: [], down: false, isRepeat: false) == .pass)
    }

    @Test func overviewKeyPressedAgainWhileOpenIsSwallowed() throws {
        let tap = try state(bindings)
        let o = code("o")
        #expect(tap.key(code: o, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .overview(true))
        // A second press (a key-up missed) does not open it twice.
        #expect(tap.key(code: o, modifiers: [.cmd, .alt], down: true, isRepeat: false) == .swallow)
        #expect(tap.key(code: o, modifiers: [], down: false, isRepeat: false) == .overview(false))
    }

    /// Two modifier-only combinations held together add up; releasing one keeps the other's.
    @Test func modifierOnlyCarriersMerge() throws {
        let tap = try state(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" }, { "from": "right_command", "to": "ctrl+cmd" } ] } }
        """#)
        let meh = try carrierCode(tap, .meh), ctrlCmd = try carrierCode(tap, [.ctrl, .cmd])
        #expect(tap.key(code: meh, modifiers: [], down: true, isRepeat: false) == .swallow)
        #expect(tap.key(code: ctrlCmd, modifiers: [], down: true, isRepeat: false) == .swallow)
        #expect(tap.heldModifiers == .hyper)
        #expect(tap.key(code: meh, modifiers: [], down: false, isRepeat: false) == .swallow)
        #expect(tap.heldModifiers == [.ctrl, .cmd])
        // Forgetting the keys lets go of the rest.
        _ = tap.resetKeys()
        #expect(tap.heldModifiers.isEmpty)
    }

    @Test func buttonsWithModifiers() throws {
        let tap = try state(#"{ "mouse": { "buttons": [ { "button": 3, "modifiers": "cmd", "action": "navigate back" } ] } }"#)
        #expect(tap.button(3, modifiers: [], down: true) == .pass)
        #expect(tap.button(3, modifiers: [], down: false) == .pass)
        #expect(tap.button(3, modifiers: [.cmd, .shift], down: true) == .pass)
        #expect(tap.button(3, modifiers: .cmd, down: true) == .run(.navigate(back: true)))
        // The release is swallowed whatever the modifiers are by then.
        #expect(tap.button(3, modifiers: [], down: false) == .swallow)
        #expect(tap.button(40, modifiers: [], down: true) == .pass)
    }

    /// After `clearButtons` (a new config, Settings capturing a button) a release owed to a press passes.
    @Test func clearedButtonsNoLongerSwallowTheirRelease() throws {
        let tap = try state(#"{ "mouse": { "buttons": [ { "button": 3, "action": "navigate back" } ] } }"#)
        #expect(tap.button(3, modifiers: [], down: true) == .run(.navigate(back: true)))
        tap.clearButtons()
        #expect(tap.button(3, modifiers: [], down: false) == .pass)
        // Suspending the buttons clears them too.
        #expect(tap.button(3, modifiers: [], down: true) == .run(.navigate(back: true)))
        tap.setButtonsSuspended(true)
        tap.setButtonsSuspended(false)
        #expect(tap.button(3, modifiers: [], down: false) == .pass)
    }
}

/// The event tap's lines in the debug report.
@Suite struct TapDiagnosticsTests {
    private let second: UInt64 = 1_000_000_000

    @Test func talliesSayHowLongAgo() {
        var tally = TapDiagnostics.Tally()
        #expect(tally.text(now: 5 * second) == "0")
        tally.add(at: 2 * second)
        tally.add(at: 3 * second)
        #expect(tally.text(now: 5 * second) == "2 (last 2 s ago)")
        #expect(tally.text(now: 303 * second) == "2 (last 5 min ago)")
        #expect(tally.text(now: 3 * 3600 * second + 3 * second) == "2 (last 3 h ago)")
        // A clock read before the last event (another thread's) is not a negative time.
        #expect(tally.text(now: second) == "2 (last 0 s ago)")
    }

    @Test func stateLineTellsWhyShortcutsAreOff() {
        var diagnostics = TapDiagnostics()
        #expect(diagnostics.lines(now: 0)[0].hasPrefix("Event tap state: not installed; key bindings active"))
        diagnostics.installed = true
        #expect(diagnostics.lines(now: 0)[0].hasPrefix("Event tap state: disabled by the system"))
        diagnostics.enabled = true
        diagnostics.keyBindingsSuspended = true
        diagnostics.held = .meh
        diagnostics.carriers = 1
        diagnostics.actions = 40
        #expect(diagnostics.lines(now: 0)[0] == "Event tap state: enabled; key bindings suspended (Settings is recording); "
            + "mouse buttons active; combination held: ⌃⌥⇧; 1 combination key(s), 40 action(s)")
    }

    @Test func seenLineCountsWithoutKeys() {
        var diagnostics = TapDiagnostics()
        diagnostics.keys.add(at: second)
        diagnostics.unbound.add(at: second)
        #expect(diagnostics.lines(now: 4 * second)[1] == "Event tap seen: key presses 1 (last 3 s ago); combination key events 0; "
            + "shortcuts run 0; presses with a combination and no shortcut 1 (last 3 s ago); switched off by the system 0")
    }
}
