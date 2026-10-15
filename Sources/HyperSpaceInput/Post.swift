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
        var flags = physical.subtracting([.maskSecondaryFn, .maskNumericPad])
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.fn) || combo.key.hasFnFlag { flags.insert(.maskSecondaryFn) }
        if combo.key.isArrow { flags.insert(.maskNumericPad) }
        return flags
    }

    /// A full click of `button` (CoreGraphics number: 0 left, 1 right, 2 middle, 3 back, 4 forward).
    static func click(_ button: Int, at location: CGPoint, count: Int64 = 1) {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case 0: (.leftMouseDown, .leftMouseUp)
        case 1: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        guard let mouseButton = CGMouseButton(rawValue: UInt32(button)) else { return }
        for type in [down, up] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: count)
            send(event)
        }
    }

    static func scroll(_ step: ScrollStep) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: step.pixels ? .pixel : .line,
                                  wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0) else { return }
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
