import AppKit
import ApplicationServices
import HyperSpaceCore

/// Named actions other than navigation and clicks, as LinearMouse does them (MIT, see
/// THIRD_PARTY.md). Anything that talks to another process (Dock, windows, hot keys) runs on
/// its own queue, so the input thread never waits.
enum SystemActions {
    private static let queue = DispatchQueue(label: "hyperspace.actions", qos: .userInitiated)

    /// Input thread.
    static func perform(_ action: SystemAction, at location: CGPoint) {
        if let key = action.mediaKey { return Post.mediaKey(key) }
        switch action {
        case .clickLeft: Post.click(0, at: location)
        case .clickDouble:
            Post.click(0, at: location)
            Post.click(0, at: location, count: 2)
        case .clickRight: Post.click(1, at: location)
        case .clickMiddle: Post.click(2, at: location)
        case .clickBack: Post.click(3, at: location)
        case .clickForward: Post.click(4, at: location)
        case .smartZoom: postSmartZoom()
        default: queue.async { performAsync(action) }
        }
    }

    private static func performAsync(_ action: SystemAction) {
        switch action {
        case .missionControl: CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)
        case .missionWindows: CoreDockSendNotification("com.apple.expose.front.awake" as CFString, 0)
        case .missionDesktop: CoreDockSendNotification("com.apple.showdesktop.awake" as CFString, 0)
        case .missionLaunchpad: CoreDockSendNotification("com.apple.launchpad.toggle" as CFString, 0)
        case .spaceLeft: postSymbolicHotKey(79)
        case .spaceRight: postSymbolicHotKey(81)
        case .lookUp: postSymbolicHotKey(70)
        case .windowMaximize: maximizeFocusedWindow()
        case .windowMinimize:
            if let window = focusedWindow() { AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        default: break
        }
    }

    /// The trackpad's two-finger double tap: a gesture event of HID type zoom toggle.
    private static func postSmartZoom() {
        guard let event = CGEvent(source: nil),
              let gesture = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) else { return }
        event.type = gesture
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 22) // gesture HID type: kIOHIDEventTypeZoomToggle
        Post.send(event)
    }

    // MARK: - Symbolic hot keys

    /// Presses the shortcut System Settings assigns to a symbolic hot key (e.g. ⌃← for the
    /// space on the left), turning it on for the moment if the user turned it off.
    private static func postSymbolicHotKey(_ hotKey: UInt32) {
        var character: UInt16 = 0, code: UInt16 = 0, modifiers: UInt32 = 0
        // 0xFFFF = shortcut cleared; 0 without a character = never assigned (0 is the A key).
        guard CGSGetSymbolicHotKeyValue(hotKey, &character, &code, &modifiers) == 0,
              code != 0xFFFF, code != 0 || character != 0xFFFF else { return }
        let wasEnabled = CGSIsSymbolicHotKeyEnabled(hotKey)
        if !wasEnabled { CGSSetSymbolicHotKeyEnabled(hotKey, true) }

        // Real modifier presses around the key, or the system would keep them "held".
        let flags = CGEventFlags(rawValue: UInt64(modifiers))
        let modifierKeys: [(CGEventFlags, UInt16)] = [(.maskShift, 0x38), (.maskControl, 0x3B), (.maskAlternate, 0x3A), (.maskCommand, 0x37)]
            .filter { flags.contains($0.0) }
        var held: CGEventFlags = []
        for (flag, key) in modifierKeys {
            held.insert(flag)
            postFlagsChanged(key, held)
        }
        Post.key(code, down: true, flags: flags)
        Post.key(code, down: false, flags: flags)
        for (flag, key) in modifierKeys.reversed() {
            held.remove(flag)
            postFlagsChanged(key, held)
        }

        if !wasEnabled {
            queue.asyncAfter(deadline: .now() + .milliseconds(200)) { CGSSetSymbolicHotKeyEnabled(hotKey, false) }
        }
    }

    private static func postFlagsChanged(_ key: UInt16, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: Post.source, virtualKey: key, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        Post.send(event)
    }

    // MARK: - Windows

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Fills the visible area (menu bar and Dock excluded) of the screen the window is on.
    private static func maximizeFocusedWindow() {
        guard let window = focusedWindow(), let primary = NSScreen.screens.first else { return }
        // AX uses top-left coordinates, AppKit bottom-left.
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        let frame = CGRect(x: position.x, y: primary.frame.maxY - position.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area } ?? primary
        let visible = screen.visibleFrame
        var target = CGPoint(x: visible.minX, y: primary.frame.maxY - visible.maxY)
        var targetSize = visible.size
        guard let positionValue = AXValueCreate(.cgPoint, &target), let sizeValue = AXValueCreate(.cgSize, &targetSize) else { return }
        // Size, position, size: a window can't move where its old size wouldn't fit.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// Private APIs, as used by LinearMouse and other input utilities.
@discardableResult @_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ notification: CFString, _ unknown: Int32) -> Int32
@_silgen_name("CGSGetSymbolicHotKeyValue")
private func CGSGetSymbolicHotKeyValue(_ hotKey: UInt32, _ character: UnsafeMutablePointer<UInt16>,
                                       _ code: UnsafeMutablePointer<UInt16>, _ modifiers: UnsafeMutablePointer<UInt32>) -> Int32
@_silgen_name("CGSIsSymbolicHotKeyEnabled")
private func CGSIsSymbolicHotKeyEnabled(_ hotKey: UInt32) -> Bool
@discardableResult @_silgen_name("CGSSetSymbolicHotKeyEnabled")
private func CGSSetSymbolicHotKeyEnabled(_ hotKey: UInt32, _ enabled: Bool) -> Int32
