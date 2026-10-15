import AppKit
import HyperSpaceCore

/// Sends media keys the way a keyboard's function row does: a system-defined event
/// (subtype 8, `NX_SUBTYPE_AUX_CONTROL_BUTTONS`) per press and release. macOS shows its
/// own volume/brightness overlay and routes playback to the app that is playing.
enum MediaKeys {
    static func post(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00 // NX_KEYDOWN / NX_KEYUP, shifted into data1
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (key.rawValue << 16) | state, data2: -1
            )?.cgEvent else { continue }
            event.post(tap: .cghidEventTap)
        }
    }
}
