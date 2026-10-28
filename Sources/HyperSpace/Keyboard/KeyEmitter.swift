import CoreGraphics

/// Posts synthetic key strokes (the `key <combo>` action).
enum KeyEmitter {
    /// A private source so physically held keys (e.g. the hyper key) don't leak into the stroke.
    private static let source = CGEventSource(stateID: .privateState)

    static func post(_ combo: KeyCombo) {
        let flags = combo.modifiers.cgFlags
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down) else { return }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
