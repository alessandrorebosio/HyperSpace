import AppKit

/// The mouse pointer, in global top-left coordinates (those of AX and CGEvent).
enum Pointer {
    /// Where the pointer is; nil only if the window server cannot say. Safe on any thread: a
    /// CGEvent made from nothing is located at the pointer, already in these coordinates.
    static var eventLocation: CGPoint? { CGEvent(source: nil)?.location }

    /// Where the pointer is, falling back to AppKit's location (main thread).
    static var location: CGPoint {
        if let location = eventLocation { return location }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: ScreenInfo.primaryHeight - mouse.y)
    }

    /// Moves the pointer without freezing it afterwards (a plain warp ignores the mouse briefly).
    static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// A native "back" (button 3) or "forward" (button 4) mouse click at the pointer.
    static func navigationButton(back: Bool) {
        let number: Int64 = back ? 3 : 4
        click(down: .otherMouseDown, up: .otherMouseUp, button: .center) {
            $0.setIntegerValueField(.mouseEventButtonNumber, value: number)
        }
    }

    /// Left click with modifiers held, at `point` (global top-left coordinates) or at the pointer.
    static func click(_ mods: Modifiers, at point: CGPoint? = nil) {
        click(down: .leftMouseDown, up: .leftMouseUp, button: .left, at: point) { $0.flags = mods.cgFlags }
    }

    /// A press and a release at `point` or the pointer, marked as ours so the tap lets them
    /// through; `configure` adjusts each event before it is posted.
    private static func click(down: CGEventType, up: CGEventType, button: CGMouseButton, at point: CGPoint? = nil,
                              configure: (CGEvent) -> Void) {
        guard let location = point ?? eventLocation else { return }
        for type in [down, up] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
            configure(event)
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
