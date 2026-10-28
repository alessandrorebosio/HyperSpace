import CoreGraphics

/// Posts synthetic key strokes (the `key <combo>` action and key combinations).
enum KeyEmitter {
    /// A private source so physically held keys don't leak into the stroke.
    private static let source = CGEventSource(stateID: .privateState)

    static func post(_ combo: KeyCombo) {
        post(keyCode: combo.keyCode, flags: combo.modifiers.cgFlags, down: true)
        post(keyCode: combo.keyCode, flags: combo.modifiers.cgFlags, down: false)
    }

    /// Safe to call from the event tap thread.
    static func post(keyCode: UInt16, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
