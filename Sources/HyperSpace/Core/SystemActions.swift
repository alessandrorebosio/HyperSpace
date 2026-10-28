import AppKit
import ApplicationServices

/// Back/forward that works in every app, whatever the keyboard layout or language.
///
/// 1. Xcode: ⌃⌘← / ⌃⌘→ (arrow keys do not depend on the layout).
/// 2. Press the app's own menu item whose shortcut is ⌘[ / ⌘] (Safari, Finder, Chrome, Mail…)
///    or ⌃- / ⌃⇧- (VS Code-like editors), found through Accessibility by its shortcut, not
///    its title. Sending ⌘[ as a key stroke would fail on layouts where [ is not a plain key.
/// 3. Otherwise a native back/forward mouse button, handled by Chrome, Firefox, Electron
///    and JetBrains apps on their own.
enum Navigation {
    private struct Shortcut {
        let char: String
        /// kAXMenuItemModifier* bits: 1 shift, 2 option, 4 control, 8 no command.
        let modifiers: Int
    }

    private static let backShortcuts = [Shortcut(char: "[", modifiers: 0), Shortcut(char: "-", modifiers: 4 | 8)]
    private static let forwardShortcuts = [Shortcut(char: "]", modifiers: 0), Shortcut(char: "-", modifiers: 1 | 4 | 8)]
    private static let xcode = (back: try! KeyCombo.parse("ctrl+cmd+left"), forward: try! KeyCombo.parse("ctrl+cmd+right"))

    /// Menu items found per app, so the menu bar is searched once.
    private static var cache: [pid_t: [Bool: AXUIElement]] = [:]
    private static var lastPruned = Date.distantPast

    static func perform(back: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if app.bundleIdentifier == "com.apple.dt.Xcode" {
            KeyEmitter.post(back ? xcode.back : xcode.forward)
            return
        }
        if pressMenuItem(of: app.processIdentifier, back: back) { return }
        Pointer.navigationButton(back: back)
    }

    private static func pressMenuItem(of pid: pid_t, back: Bool) -> Bool {
        pruneCache()
        if let item = cache[pid]?[back] {
            let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if result != .invalidUIElement && result != .cannotComplete { return true }
            cache[pid]?[back] = nil // the app rebuilt its menus
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let menuBar = AX.element(app, kAXMenuBarAttribute),
              let item = find(back ? backShortcuts : forwardShortcuts, under: menuBar, depth: 5) else { return false }
        cache[pid, default: [:]][back] = item
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        return true
    }

    /// Depth-first through menu bar items, menus, items and submenus. Each element costs
    /// a single AX round trip: shortcut and children are fetched together.
    private static func find(_ shortcuts: [Shortcut], under element: AXUIElement, depth: Int) -> AXUIElement? {
        let attributes = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute] as CFArray
        for child in AX.elements(element, kAXChildrenAttribute) {
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(child, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [Any], list.count == 3 else { continue }
            if let char = list[0] as? String, let modifiers = (list[1] as? NSNumber)?.intValue,
               shortcuts.contains(where: { $0.char == char && $0.modifiers == modifiers }) {
                return child
            }
            if depth > 0, let children = list[2] as? [AXUIElement], !children.isEmpty,
               let found = find(shortcuts, under: child, depth: depth - 1) {
                return found
            }
        }
        return nil
    }

    private static func pruneCache() {
        guard Date().timeIntervalSince(lastPruned) > 300 else { return }
        lastPruned = Date()
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        cache = cache.filter { running.contains($0.key) }
    }
}

@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ notification: CFString, _ unknown: Int32)

/// Mission Control family, triggered through the Dock (works even when their
/// keyboard shortcuts are disabled or changed).
enum SystemAction: String {
    case missionControl = "mission_control"
    case appWindows = "app_windows"
    case showDesktop = "show_desktop"

    func perform() {
        let notification: String
        switch self {
        case .missionControl: notification = "com.apple.expose.awake"
        case .appWindows: notification = "com.apple.expose.front.awake"
        case .showDesktop: notification = "com.apple.showdesktop.awake"
        }
        CoreDockSendNotification(notification as CFString, 0)
    }
}

/// Media keys, posted as the same system-defined events the keyboard sends.
enum MediaKey: String {
    case playPause = "play_pause"
    case next
    case previous
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case mute

    /// NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h.
    private var keyType: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        case .next: return 19
        case .previous: return 20
        }
    }

    func post() {
        for down in [true, false] {
            let state = down ? 0xA00 : 0xB00
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: keyType << 16 | state, data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

enum Pointer {
    /// A native "back" (button 3) or "forward" (button 4) mouse click at the pointer.
    static func navigationButton(back: Bool) {
        guard let location = CGEvent(source: nil)?.location else { return }
        let number: Int64 = back ? 3 : 4
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .center) else { return }
            event.setIntegerValueField(.mouseEventButtonNumber, value: number)
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Left click at the current pointer position with modifiers held.
    static func click(_ mods: Modifiers) {
        guard let location = CGEvent(source: nil)?.location else { return }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { return }
            event.flags = mods.cgFlags
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
