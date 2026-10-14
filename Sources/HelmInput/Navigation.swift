import AppKit
import CoreGraphics
import HelmCore

/// Universal back/forward, as LinearMouse does it (MIT, see THIRD_PARTY.md).
///
/// Sending ⌘[ by key code breaks on non-US layouts (on Italian it's `è`/`+`, so Safari zooms),
/// and the menu shortcut itself is localized (Safari's Back is ⌘ò on Italian). Instead:
/// - apps that support trackpad navigation swipes (Apple apps, Firefox...) get a synthesized
///   two-finger swipe, like the trackpad sends;
/// - every other app gets mouse button 4/5, which browsers and editors handle natively.
///
/// Input thread only.
struct NavigationSender {
    /// Apps known to handle navigation swipes but not mouse buttons 4/5.
    private static let swipeApps = ["com.apple.", "org.mozilla.firefox", "com.operasoftware.Opera", "com.binarynights.ForkLift"]

    private var swipeByPID: [pid_t: Bool] = [:]

    mutating func send(_ direction: Navigation, targetPID: pid_t, location: CGPoint) {
        if usesSwipe(targetPID) {
            NavigationSender.postSwipe(direction)
        } else {
            NavigationSender.postButton(direction, at: location)
        }
    }

    private mutating func usesSwipe(_ pid: pid_t) -> Bool {
        if let cached = swipeByPID[pid] { return cached }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let swipe = NavigationSender.swipeApps.contains { bundleID.hasPrefix($0) }
        if swipeByPID.count > 64 { swipeByPID.removeAll() } // pids of quit apps
        swipeByPID[pid] = swipe
        return swipe
    }

    // Private CGEvent gesture fields, from WebKit's CoreGraphicsTestSPI.h.
    private static let gestureHIDType = CGEventField(rawValue: 110)!
    private static let gestureSwipeValue = CGEventField(rawValue: 115)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let navigationSwipeType: Int64 = 16 // IOHIDEventType
    private static let phaseBegan: Int64 = 1, phaseEnded: Int64 = 4
    private static let swipeLeft: Int64 = 0x04, swipeRight: Int64 = 0x08 // IOHIDSwipeMask

    private static func postSwipe(_ direction: Navigation) {
        guard let began = CGEvent(source: nil), let ended = CGEvent(source: nil),
              let gesture = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) else { return }
        for (event, phase) in [(began, phaseBegan), (ended, phaseEnded)] {
            event.type = gesture
            event.setIntegerValueField(gestureHIDType, value: navigationSwipeType)
            event.setIntegerValueField(gesturePhase, value: phase)
            event.setIntegerValueField(.eventSourceUserData, value: InputTap.marker)
        }
        began.setIntegerValueField(gestureSwipeValue, value: direction == .back ? swipeLeft : swipeRight)
        began.post(tap: .cgSessionEventTap)
        ended.post(tap: .cgSessionEventTap)
    }

    /// Mouse buttons 4/5 (CoreGraphics numbers 3/4), marked so the tap lets them through.
    private static func postButton(_ direction: Navigation, at location: CGPoint) {
        let button = CGMouseButton(rawValue: direction == .back ? 3 : 4)!
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: InputTap.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}
