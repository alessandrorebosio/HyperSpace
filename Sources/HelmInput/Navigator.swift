import ApplicationServices
import CoreGraphics
import Foundation
import HelmCore

/// Back/forward that works with any keyboard layout. Sending ⌘[ by key code breaks on
/// non-US layouts (on Italian the same key is `è` and ⌘] becomes ⌘+, i.e. zoom), so instead
/// we press the frontmost app's Back/Forward menu item through Accessibility.
/// Apps without such an item (Chrome, VS Code...) get mouse button 4/5, which they handle natively.
///
/// Runs on its own serial queue: AX calls can take tens of ms and must never block input.
public final class Navigator: @unchecked Sendable {
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

        let item = Navigator.findMenuItem(in: AXUIElementCreateApplication(pid), direction: direction)
        cache[pid, default: [:]][direction] = .some(item)
        if let item, AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            let title: String = Navigator.attribute(item, kAXTitleAttribute) ?? "?"
            log.info("pid \(pid): \(String(describing: direction), privacy: .public) via menu item '\(title, privacy: .public)'")
            return
        }
        log.info("pid \(pid): no \(String(describing: direction), privacy: .public) menu item, using mouse button")
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

    /// Menu titles of the back/forward commands in common languages. Needed because AppKit
    /// localizes shortcuts per keyboard layout: on Italian, Safari's Back is ⌘ò, not ⌘[.
    private static let titles: [Navigation: Set<String>] = [
        .back: ["back", "go back", "indietro", "zurück", "précédent", "retour", "atrás", "voltar", "terug"],
        .forward: ["forward", "go forward", "avanti", "vorwärts", "suivant", "avancer", "adelante", "avançar", "vooruit"],
    ]

    /// Depth-first search of the menu bar for the back/forward item: first by its standard
    /// shortcut (⌘[ / ⌘]), then by title among items that have a ⌘ shortcut.
    private static func findMenuItem(in app: AXUIElement, direction: Navigation) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        let shortcut = direction == .back ? "[" : "]"
        let wantedTitles = titles[direction] ?? []
        var byTitle: AXUIElement?
        var stack = children(menuBar)
        var visited = 0
        while let element = stack.popLast(), visited < 2000 {
            visited += 1
            let names = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute, kAXTitleAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let array = values as? [Any], array.count == 4 else { continue }
            if let kids = array[2] as? [AXUIElement] { stack.append(contentsOf: kids) }
            // Modifiers 0 means ⌘ only.
            guard let char = array[0] as? String, !char.isEmpty, (array[1] as? Int) == 0 else { continue }
            if char == shortcut { return element }
            if byTitle == nil, let title = array[3] as? String, wantedTitles.contains(title.lowercased()) {
                byTitle = element
            }
        }
        return byTitle
    }

    /// Every menu item with a shortcut, for `helmctl debug-menu`: title, char, modifiers, virtual key.
    public static func dumpMenu(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return "no menu bar (pid \(pid))" }
        var lines: [String] = []
        var stack = children(menuBar)
        while let element = stack.popLast(), lines.count < 1000 {
            let names = [kAXTitleAttribute, kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute,
                         kAXMenuItemCmdVirtualKeyAttribute, kAXChildrenAttribute] as CFArray
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let a = values as? [Any], a.count == 5 else { continue }
            if let kids = a[4] as? [AXUIElement] { stack.append(contentsOf: kids) }
            let char = a[1] as? String ?? ""
            let key = a[3] as? Int
            guard !char.isEmpty || key != nil else { continue }
            lines.append("\(a[0] as? String ?? "?")\tchar=\(char.debugDescription)\tmods=\(a[2])\tvkey=\(key.map(String.init) ?? "-")")
        }
        return lines.joined(separator: "\n")
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
