import CoreGraphics

/// What the event tap decides about keys and mouse buttons, apart from the events themselves:
/// which presses run an action, which key-ups and button-ups are swallowed with them, the
/// modifiers of the combinations held, the overview key, and suspension while Settings records.
/// Pure and owned by the tap thread (`EventTap`), so every decision can be tested.
/// No allocation on the hot path: plain arrays sized once per config.
struct TapState {
    /// What to do with a key or button event.
    enum Decision: Equatable {
        /// Let it through (to the app in front).
        case pass
        /// Drop it.
        case swallow
        /// Drop it and run the action.
        case run(Action)
        /// Drop it and show (true) or hide the workspace overview.
        case overview(Bool)
        /// Drop it and post this key with these modifiers instead (a combination's carrier).
        case postKey(keyCode: UInt16, modifiers: Modifiers, down: Bool)
    }

    /// In `pressedActions`: the key is not held by a binding.
    private static let notPressed: Int16 = -1

    private(set) var config = TapConfig()
    /// Modifiers of the modifier-only combinations currently held (e.g. caps lock → ⌃⌥⇧).
    private(set) var heldModifiers: Modifiers = []
    private var carrierDown: [Bool] = []
    /// By key code: the index in `config.actions` of the binding a held key pressed, or
    /// `notPressed`. Its autorepeat and its key-up belong to that binding, whatever the
    /// modifiers are by then, and are swallowed with it.
    private var pressedActions = [Int16](repeating: TapState.notPressed, count: TapConfig.keyCodeCount)
    private var swallowedButtons = [Bool](repeating: false, count: TapConfig.buttonCount)
    /// The key code holding the workspace overview open, or -1.
    private var overviewKey = -1
    /// Set while the settings window captures a mouse button: buttons reach the app unmapped.
    private var buttonsSuspended = false
    /// Set while the settings window captures a shortcut: key bindings are ignored
    /// (combination keys still work, so caps lock → ⌃⌥⇧ can be part of the shortcut).
    private var keyBindingsSuspended = false

    /// A new config: everything held or swallowed is forgotten. True when the overview was
    /// open and must close.
    mutating func setConfig(_ newConfig: TapConfig) -> Bool {
        config = newConfig
        clearButtons()
        return resetKeys()
    }

    /// Forgets the keys, carriers and modifiers held or swallowed, so nothing stays stuck
    /// (a new config, the lock). True when the overview was open and must close.
    mutating func resetKeys() -> Bool {
        if carrierDown.count == config.carriers.count {
            for i in carrierDown.indices { carrierDown[i] = false }
        } else {
            carrierDown = [Bool](repeating: false, count: config.carriers.count)
        }
        heldModifiers = []
        return releasePressedKeys()
    }

    /// The button-ups still owed to a swallowed press are not swallowed any more.
    mutating func clearButtons() {
        for i in swallowedButtons.indices { swallowedButtons[i] = false }
    }

    /// True when the overview was open and must close.
    mutating func setKeyBindingsSuspended(_ suspended: Bool) -> Bool {
        keyBindingsSuspended = suspended
        return releasePressedKeys()
    }

    mutating func setButtonsSuspended(_ suspended: Bool) {
        buttonsSuspended = suspended
        clearButtons()
    }

    /// The key-ups still owed to a binding are not swallowed any more, and the overview is
    /// released. True when it was open and must close.
    private mutating func releasePressedKeys() -> Bool {
        for i in pressedActions.indices { pressedActions[i] = Self.notPressed }
        guard overviewKey >= 0 else { return false }
        overviewKey = -1
        return true
    }

    /// A key down or up. `modifiers`: the event's, held combinations included; `isRepeat`:
    /// the key's autorepeat.
    mutating func key(code: Int, modifiers: Modifiers, down: Bool, isRepeat: Bool) -> Decision {
        guard (0..<TapConfig.keyCodeCount).contains(code) else { return .pass }

        let carrierIndex = Int(config.carrierTable[code])
        if carrierIndex >= 0 { return carrier(carrierIndex, modifiers: modifiers, down: down) }
        let pressed = pressedActions[code]
        if !down {
            guard pressed != Self.notPressed else { return .pass }
            pressedActions[code] = Self.notPressed
            if code == overviewKey {
                overviewKey = -1
                return .overview(false)
            }
            return .swallow
        }
        if isRepeat {
            // The autorepeat of a key belongs to its press: a binding's is swallowed (and runs
            // it again if it moves in steps) even after a modifier is released; the repeats of
            // a key the app got stay with the app. (The overview does not repeat: held open.)
            guard pressed != Self.notPressed else { return .pass }
            let action = config.actions[Int(pressed)]
            return action.repeats ? .run(action) : .swallow
        }
        if keyBindingsSuspended { return .pass }
        let index = config.keyTable[TapConfig.slot(code, modifiers)]
        guard index >= 0 else {
            // A new press of a key whose key-up was missed: it is the app's now.
            pressedActions[code] = Self.notPressed
            return .pass
        }
        pressedActions[code] = index
        let action = config.actions[Int(index)]
        if action == .workspaceOverview {
            // Open while the key is down: the key up closes it.
            guard overviewKey != code else { return .swallow }
            overviewKey = code
            return .overview(true)
        }
        return .run(action)
    }

    /// A carrier key stands for a combination: modifier-only combinations are held
    /// while it is down; combinations with a key press that key with the modifiers.
    private mutating func carrier(_ index: Int, modifiers: Modifiers, down: Bool) -> Decision {
        let carrier = config.carriers[index]
        if let keyCode = carrier.keyCode {
            return .postKey(keyCode: keyCode, modifiers: modifiers.union(carrier.modifiers), down: down)
        }
        guard carrierDown[index] != down else { return .swallow } // autorepeat
        carrierDown[index] = down
        var held: Modifiers = []
        for (i, isDown) in carrierDown.enumerated() where isDown { held.formUnion(config.carriers[i].modifiers) }
        heldModifiers = held
        return .swallow
    }

    /// A mouse button (other than left and right) down or up.
    mutating func button(_ button: Int, modifiers: Modifiers, down: Bool) -> Decision {
        guard (0..<TapConfig.buttonCount).contains(button), !buttonsSuspended else { return .pass }
        if down {
            let index = config.buttonTable[TapConfig.slot(button, modifiers)]
            guard index >= 0 else { return .pass }
            swallowedButtons[button] = true
            return .run(config.actions[Int(index)])
        }
        guard swallowedButtons[button] else { return .pass }
        swallowedButtons[button] = false
        return .swallow
    }
}
