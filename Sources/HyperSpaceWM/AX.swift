import ApplicationServices
import Foundation
import HyperSpaceCore

/// Thin typed wrappers over AXUIElement attribute calls. Each one is an IPC round trip to
/// the app: call them on the app's queue, never on the main or input thread.
enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? { value(element, attribute) }
    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { value(element, attribute) }

    static func windowID(_ element: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(element, kAXPositionAttribute),
              let size: AXValue = value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Sets only what changed between `old` and `new`: one call instead of two when a
    /// window just moves or just resizes. Size, position, size when both change, so a
    /// window growing near a screen edge isn't clamped by its old size.
    static func setFrame(_ element: AXUIElement, _ new: CGRect, old: CGRect?) {
        let moves = old?.origin != new.origin, resizes = old?.size != new.size
        if resizes, moves { setSize(element, new.size) }
        if moves { setPosition(element, new.origin) }
        if resizes { setSize(element, new.size) }
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func close(_ element: AXUIElement) {
        if let button: AXUIElement = value(element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }
}

/// What the window server knows about windows: no IPC to the apps, safe on any thread.
enum WindowServer {
    /// Bounds and visibility of `ids`, in one call. Windows that no longer exist are missing.
    static func windows(_ ids: [WindowID]) -> [WindowID: (bounds: CGRect, onscreen: Bool)] {
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let infos = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [:] }
        var windows: [WindowID: (bounds: CGRect, onscreen: Bool)] = [:]
        for info in infos {
            guard let id = info[kCGWindowNumber as String] as? WindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            windows[id] = (bounds, info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        return windows
    }
}

/// Private but stable since 10.6 and used by every macOS window manager: the CGWindowID
/// behind an AX window element.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
