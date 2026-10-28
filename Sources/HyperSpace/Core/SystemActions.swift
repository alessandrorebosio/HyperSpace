import AppKit
import ApplicationServices

/// Back/forward that works across apps: most use ⌘[ / ⌘], a few have their own shortcut.
enum Navigation {
    private static let back = try! KeyCombo.parse("cmd+[")
    private static let forward = try! KeyCombo.parse("cmd+]")

    /// Bundle id prefix → (back, forward).
    private static let overrides: [(prefix: String, back: KeyCombo, forward: KeyCombo)] = {
        let editor = (try! KeyCombo.parse("ctrl+-"), try! KeyCombo.parse("ctrl+shift+-"))
        let xcode = (try! KeyCombo.parse("ctrl+cmd+left"), try! KeyCombo.parse("ctrl+cmd+right"))
        return [
            ("com.microsoft.VSCode", editor.0, editor.1),
            ("com.vscodium", editor.0, editor.1),
            ("com.todesktop.230313mzl4w4u92", editor.0, editor.1), // Cursor
            ("com.exafunction.windsurf", editor.0, editor.1),
            ("dev.zed.Zed", editor.0, editor.1),
            ("com.apple.dt.Xcode", xcode.0, xcode.1),
        ]
    }()

    static func perform(back isBack: Bool) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let match = overrides.first { bundleID.hasPrefix($0.prefix) }
        KeyEmitter.post(isBack ? (match?.back ?? back) : (match?.forward ?? forward))
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
