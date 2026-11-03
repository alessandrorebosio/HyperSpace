import AppKit
import ApplicationServices

/// Maps an AX window element to its CGWindowID. Private but stable for a decade
/// (used by yabai, Amethyst, AeroSpace, Rectangle); avoids Screen Recording.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, allocation-light helpers over the Accessibility C API.
enum AX {
    static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // On the system-wide element this is the timeout of every element.
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }()

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = value(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = value(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ flag: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse)
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func pid(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// Everything tracking a window needs, read in one go off the main thread.
    struct WindowProbe {
        enum Kind {
            /// A regular, movable app window: tiled.
            case standard
            /// A movable dialog (alert, detached panel): floats in its parent's workspace.
            case dialog
            /// Not ready yet (no role or subrole): apps fill them in a moment after creating the window.
            case pending
            /// Anything else (sheets, popovers, the Finder desktop): left alone.
            case other
        }

        let element: AXUIElement
        let id: CGWindowID?
        let role: String?
        let subrole: String?
        let kind: Kind
        /// A standard window that behaves as a dialog (see `isDialogLike`).
        let dialogLike: Bool
        let title: String?
        let frame: CGRect?
        /// The app's main window, the likely parent of a dialog.
        let mainWindow: CGWindowID?
    }

    static func probe(_ element: AXUIElement, pid: pid_t) -> WindowProbe {
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        var settable: DarwinBoolean = false
        let movable = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        let kind: WindowProbe.Kind
        switch (role, subrole) {
        case (kAXWindowRole, kAXStandardWindowSubrole): kind = movable ? .standard : .other
        case (kAXWindowRole, kAXDialogSubrole), (kAXWindowRole, kAXSystemDialogSubrole): kind = movable ? .dialog : .other
        case (nil, _), (kAXWindowRole, nil), (kAXWindowRole, kAXUnknownSubrole): kind = .pending
        default: kind = .other
        }
        let frame = position(element).flatMap { origin in size(element).map { CGRect(origin: origin, size: $0) } }
        let main = kind == .other ? nil : self.element(AXUIElementCreateApplication(pid), kAXMainWindowAttribute).flatMap(windowID)
        return WindowProbe(element: element, id: windowID(element), role: role, subrole: subrole, kind: kind,
                           dialogLike: kind == .standard && isDialogLike(element),
                           title: kind == .other ? nil : string(element, kAXTitleAttribute), frame: frame, mainWindow: main)
    }

    /// Raises a window above its app's others, without focusing it.
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// A standard window that is really a dialog, like the Finder's Empty Trash or Copy
    /// progress: it can be closed but neither zoomed nor made full screen. Windows with no
    /// title bar buttons at all (borderless terminals) are not dialogs.
    static func isDialogLike(_ element: AXUIElement) -> Bool {
        guard self.element(element, kAXCloseButtonAttribute) != nil,
              self.element(element, kAXFullScreenButtonAttribute) == nil else { return false }
        guard let zoom = self.element(element, kAXZoomButtonAttribute) else { return true }
        return bool(zoom, kAXEnabledAttribute) == false
    }

    /// The window under a screen point (global top-left coordinates).
    static func window(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        if string(hit, kAXRoleAttribute) == kAXWindowRole { return hit }
        return element(hit, kAXWindowAttribute) ?? element(hit, kAXTopLevelUIElementAttribute)
    }

    /// The pointer in global top-left coordinates.
    static var pointer: CGPoint {
        // A CGEvent made from nothing is located at the pointer, already in these coordinates.
        if let location = CGEvent(source: nil)?.location { return location }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
    }

    /// Moves the pointer without freezing it afterwards (a plain warp ignores the mouse briefly).
    static func warpPointer(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Raises a window and makes its app frontmost. Works from a background
    /// accessory app, unlike NSRunningApplication.activate on recent macOS.
    static func focus(_ window: AXUIElement, pid: pid_t) {
        setBool(window, kAXMainAttribute, true)
        setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
