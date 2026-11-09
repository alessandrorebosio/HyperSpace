import AppKit

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
        asElement(value(element, attribute))
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        value(element, attribute) as? [AXUIElement] ?? []
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        point(value(element, kAXPositionAttribute))
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        size(value(element, kAXSizeAttribute))
    }

    /// Position and size in one round trip.
    static func frame(_ element: AXUIElement) -> CGRect? {
        let list = values(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let list, let origin = point(list[0]), let size = size(list[1]) else {
            // Not answered as a batch: one at a time.
            return position(element).flatMap { origin in size(element).map { CGRect(origin: origin, size: $0) } }
        }
        return CGRect(origin: origin, size: size)
    }

    /// Several attributes in one round trip, in order, a missing one as nil; nil when the app
    /// does not answer the batch at all.
    static func values(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as [AnyObject]?, list.count == attributes.count else { return nil }
        // A missing attribute comes back as an AXValue holding its error.
        return list.map { value in
            CFGetTypeID(value) == AXValueGetTypeID() && AXValueGetType(value as! AXValue) == .axError ? nil : value
        }
    }

    private static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func asElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

    /// `main` is the app's main window ID when the caller already resolved it (once per app
    /// for a batch); left `nil` it is read here.
    static func probe(_ element: AXUIElement, pid: pid_t, main resolved: CGWindowID?? = nil) -> WindowProbe {
        // Everything readable in one round trip (each would be one, and an app slow to answer
        // makes each slow); one at a time for an app that does not answer the batch.
        let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute,
                          kAXCloseButtonAttribute, kAXFullScreenButtonAttribute, kAXZoomButtonAttribute]
        let list = values(element, attributes) ?? attributes.map { value(element, $0) }
        let role = list[0] as? String
        let subrole = list[1] as? String
        var settable: DarwinBoolean = false
        let movable = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        let kind: WindowProbe.Kind
        switch (role, subrole) {
        case (kAXWindowRole, kAXStandardWindowSubrole): kind = movable ? .standard : .other
        case (kAXWindowRole, kAXDialogSubrole), (kAXWindowRole, kAXSystemDialogSubrole): kind = movable ? .dialog : .other
        case (nil, _), (kAXWindowRole, nil), (kAXWindowRole, kAXUnknownSubrole): kind = .pending
        default: kind = .other
        }
        let frame = point(list[2]).flatMap { origin in size(list[3]).map { CGRect(origin: origin, size: $0) } }
        let main = kind == .other ? nil
            : resolved ?? self.element(AXUIElementCreateApplication(pid), kAXMainWindowAttribute).flatMap(windowID)
        return WindowProbe(element: element, id: windowID(element), role: role, subrole: subrole, kind: kind,
                           dialogLike: kind == .standard && isDialogLike(close: asElement(list[5]), fullScreen: asElement(list[6]),
                                                                         zoom: asElement(list[7])),
                           title: kind == .other ? nil : list[4] as? String, frame: frame, mainWindow: main)
    }

    /// Raises a window above its app's others, without focusing it.
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// A standard window that is really a dialog, like the Finder's Empty Trash or Copy
    /// progress: it can be closed but neither zoomed nor made full screen. Windows with no
    /// title bar buttons at all (borderless terminals) are not dialogs. Takes the window's buttons.
    static func isDialogLike(close: AXUIElement?, fullScreen: AXUIElement?, zoom: AXUIElement?) -> Bool {
        guard close != nil, fullScreen == nil else { return false }
        guard let zoom else { return true }
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

    /// Raises a window and makes its app frontmost. Works from a background
    /// accessory app, unlike NSRunningApplication.activate on recent macOS.
    static func focus(_ window: AXUIElement, pid: pid_t) {
        setBool(window, kAXMainAttribute, true)
        setBool(AXUIElementCreateApplication(pid), kAXFrontmostAttribute, true)
        raise(window)
    }
}
