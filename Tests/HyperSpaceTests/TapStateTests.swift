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
}

/// The event tap's decisions about keys and buttons.
@Suite struct TapStateTests {
    private func state(_ json: String) throws -> Tap {
        let tap = Tap()
        _ = tap.setConfig(try config(json).tap)
        return tap
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
        #expect(tap.key(code: code("h"), modifiers: [.cmd, .alt], down: true, isRepeat: true) == .run(.focus(.left)))
        #expect(tap.key(code: code("f"), modifiers: [.cmd, .alt], down: true, isRepeat: false) == .run(.toggleFloat))
        #expect(tap.key(code: code("f"), modifiers: [.cmd, .alt], down: true, isRepeat: true) == .swallow)
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
}
