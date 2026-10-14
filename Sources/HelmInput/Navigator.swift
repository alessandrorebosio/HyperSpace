import ApplicationServices
import CoreGraphics
import Foundation
import HelmCore

/// Back/forward that works with any keyboard layout. Sending ⌘[ by key code breaks on
/// non-US layouts (on Italian the same key is `è` and ⌘] becomes ⌘+, i.e. zoom), so instead
/// we press the frontmost app's menu item whose shortcut is ⌘[ / ⌘] through Accessibility.
/// Apps without such an item (Chrome, VS Code...) get mouse button 4/5, which they handle natively.
///
/// Runs on its own serial queue: AX calls can take tens of ms and must never block input.
final class Navigator: @unchecked Sendable {
    private let log = Helm.logger("navigator")
    private let queue = DispatchQueue(label: "helm.navigator", qos: .userInteractive)

    // Queue only. Found menu items per app; `nil` value = the app has none.
    private var cache: [pid_t: [Navigation: AXUIElement?]] = [:]

    func navigate(_ direction: Navigation) {
        queue.async { self.run(direction) }
    }

    private func run(_ direction: Navigation) {
        guard let pid = Navigator.frontmostPID() else { return fallback(direction) }

        if let cached = cache[pid]?[direction] {
            guard let item = cached else { return fallback(direction) }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return }
            cache[pid] = nil // menu was rebuilt or the app relaunched: search again
        }

        let item = Navigator.findMenuItem(in: AXUIElementCreateApplication(pid), shortcut: direction == .back ? "[" : "]")
        cache[pid, default: [:]][direction] = .some(item)
        if let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            let title: String = Navigator.attribute(item, kAXTitleAttribute) ?? "?"
            log.info("pid \(pid): \(String(describing: direction)) via menu item '\(title)'")
            return
        }
        log.info("pid \(pid): no ⌘\(direction == .back ? "[" : "]") menu item, using mouse button")
        fallback(direction)
    }

    /// Mouse buttons 4/5 (CoreGraphics numbers 3/4) at the cursor, marked so the tap lets them through.
    private func fallback(_ direction: Navigation) {
        let button = CGMouseButton(rawValue: direction == .back ? 3 : 4)!
        let location = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: InputTap.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private static func frontmostPID() -> pid_t? {
        var app: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app) == .success,
              let app, CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(app as! AXUIElement, &pid) == .success ? pid : nil
    }

    /// Depth-first search of the menu bar for an item whose shortcut is ⌘ + `shortcut`.
    private static func findMenuItem(in app: AXUIElement, shortcut: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        var stack = children(menuBar)
        var visited = 0
        while let element = stack.popLast(), visited < 2000 {
            visited += 1
            let names = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let array = values as? [Any], array.count == 3 else { continue }
            // Modifiers 0 means ⌘ only.
            if array[0] as? String == shortcut, (array[1] as? Int) == 0 { return element }
            if let kids = array[2] as? [AXUIElement] { stack.append(contentsOf: kids) }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }
}
