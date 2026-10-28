import CoreGraphics

/// Posts synthetic key strokes (the `key <combo>` action and key combinations).
enum KeyEmitter {
    /// A private source so physically held keys don't leak into the stroke.
    private static let source = CGEventSource(stateID: .privateState)

    /// Main thread: symbol keys are translated to the current keyboard layout.
    static func post(_ combo: KeyCombo) {
        let keyCode = KeyboardLayout.keyCode(for: combo.keyCode)
        post(keyCode: keyCode, flags: combo.modifiers.cgFlags, down: true)
        post(keyCode: keyCode, flags: combo.modifiers.cgFlags, down: false)
    }

    /// Safe to call from the event tap thread.
    static func post(keyCode: UInt16, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
