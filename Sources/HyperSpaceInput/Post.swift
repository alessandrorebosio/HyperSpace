import CoreGraphics
import HyperSpaceCore
import IOKit
import IOKit.hidsystem

/// Posts synthesized input as cheaply as possible: everything is created once and reused.
/// Every event carries `InputTap.marker`, so the tap lets it through untouched.
enum Post {
    /// One `hidSystemState` source for every event: its events carry the keyboard type and
    /// HID state like real hardware (some apps and games ignore source-less events), and it
    /// isn't recreated per event. Local input is never suppressed after a post.
    nonisolated(unsafe) static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        source?.userData = InputTap.marker
        return source
    }()

    static func warmUp() {
        _ = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        _ = hidSystem
    }

    /// Sends a full key press (down + up).
    static func combo(_ combo: Combo) {
        let flags = flags(for: combo)
        key(combo.key.code, down: true, flags: flags)
        key(combo.key.code, down: false, flags: flags)
    }

    static func key(_ code: UInt16, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        send(event)
    }

    /// Physical modifiers are kept (Shift + Caps + h selects to the left), the combo's are added.
    static func flags(for combo: Combo, physical: CGEventFlags = []) -> CGEventFlags {
        var flags = physical.subtracting([.maskSecondaryFn, .maskNumericPad]).union(self.flags(for: combo.modifiers))
        if combo.key.hasFnFlag { flags.insert(.maskSecondaryFn) }
        if combo.key.isArrow { flags.insert(.maskNumericPad) }
        return flags
    }

    static func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.fn) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// Types text as Unicode, so it comes out right on any keyboard layout. Events carry at
    /// most 20 UTF-16 units each.
    static func text(_ text: String) {
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                send(event)
            }
        }
    }

    /// Where the pointer is now, for outputs that don't come from a mouse event.
    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// A full click of `button` (CoreGraphics number: 0 left, 1 right, 2 middle, 3 back, 4 forward).
    static func click(_ button: Int, at location: CGPoint, count: Int64 = 1) {
        self.button(button, down: true, at: location, count: count)
        self.button(button, down: false, at: location, count: count)
    }

    static func button(_ button: Int, down: Bool, at location: CGPoint, count: Int64 = 1) {
        let type: CGEventType = switch button {
        case 0: down ? .leftMouseDown : .leftMouseUp
        case 1: down ? .rightMouseDown : .rightMouseUp
        default: down ? .otherMouseDown : .otherMouseUp
        }
        guard let mouseButton = CGMouseButton(rawValue: UInt32(button)),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: count)
        send(event)
    }

    static func scroll(_ step: ScrollStep) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: step.pixels ? .pixel : .line,
                                  wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0) else { return }
        send(event)
    }

    /// A trackpad-like scroll by points, for smooth scrolling.
    static func smoothScroll(dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        send(event)
    }

    static func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: InputTap.marker)
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Media keys

    /// Connection to IOHIDSystem, opened on first use and kept: a media key is then a single
    /// call, delivered exactly like a keyboard's function row (macOS shows its volume and
    /// brightness overlay, playback goes to the app that is playing).
    nonisolated(unsafe) private static var hidSystem: io_connect_t = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        return IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS ? connect : 0
    }()

    /// `key` is an `NX_KEYTYPE_*` code. Input thread only.
    static func mediaKey(_ key: Int32) {
        guard hidSystem != 0 else { return }
        for down in [true, false] {
            var event = NXEventData()
            event.compound.subType = Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS)
            event.compound.misc.L.0 = key << 16 | (down ? NX_KEYDOWN : NX_KEYUP) << 8
            (HIDPoster() as any HIDPosting).post(hidSystem, &event)
        }
    }
}

/// IOHIDPostEvent is deprecated but still the one API that routes auxiliary keys through
/// IOHIDSystem like hardware (LinearMouse uses it too). Called through a protocol so the
/// deprecation warning stays here.
private protocol HIDPosting {
    func post(_ connect: io_connect_t, _ event: inout NXEventData)
}

private struct HIDPoster: HIDPosting {
    @available(macOS, deprecated: 10.12)
    func post(_ connect: io_connect_t, _ event: inout NXEventData) {
        IOHIDPostEvent(connect, UInt32(NX_SYSDEFINED), IOGPoint(x: 0, y: 0), &event,
                       UInt32(kNXEventDataVersion), 0, IOOptionBits(kIOHIDSetGlobalEventFlags))
    }
}
