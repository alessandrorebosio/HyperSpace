import AppKit
import SwiftUI

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var mods: Modifiers = []
        if flags.contains(.command) { mods.insert(.cmd) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.shift) { mods.insert(.shift) }
        self = mods
    }
}

/// An NSEvent local monitor for key or button capture. The handler returns true when
/// it consumed the event; the monitor is removed on `stop` or when released.
final class LocalEventMonitor {
    private var token: Any?

    func start(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0) ? nil : $0 }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { stop() }
}

/// A key drawn as a key cap. Clicking it starts capturing; while capturing it is
/// outlined in the accent color.
struct KeyCap: View {
    let text: String
    var symbol: String?
    /// Fixed width, padding included: keeps caps aligned from row to row.
    var width: CGFloat?
    /// Least width when the cap has no fixed one; it grows with its text, never truncating it.
    var minWidth: CGFloat = 36
    var placeholder = false
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(text).lineLimit(1).minimumScaleFactor(width == nil ? 1 : 0.8)
            }
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(active ? Color.accentColor : (placeholder ? Color.secondary : Color.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(width: width)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A compact dropdown next to a key cap, for picking from a list instead of pressing.
struct ChoiceMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "chevron.down.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
        }
        .modifier(BorderlessMenu())
        .help(help)
    }
}

/// A menu drawn as a borderless button: the dropdowns next to the key caps and the add menus
/// at the end of a list. On macOS 14+ it uses the SwiftUI button style, so the label keeps its
/// own colors and its symbols are drawn as vectors. The older borderlessButton style turns the
/// label into a gray template bitmap, which comes out blurry.
struct BorderlessMenu: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
        } else {
            content
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}

struct WarningBadge: View {
    let text: String?

    var body: some View {
        if let text {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(text)
        }
    }
}

/// Section footer: a hint, or the last save error.
struct SettingsFooter: View {
    let hint: String
    let error: String?

    var body: some View {
        Group {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                Text(hint).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// A notice at the top of a page: what is wrong and the one button that fixes it.
struct NoticeRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SidebarIcon(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(button, action: action)
        }
        .padding(.vertical, 4)
    }
}

private struct PermissionMissingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on pages whose features need the Accessibility permission, while it is missing.
    var permissionMissing: Bool {
        get { self[PermissionMissingKey.self] }
        set { self[PermissionMissingKey.self] = newValue }
    }
}

/// First section of a page that needs the Accessibility permission, shown while it is missing.
struct PermissionNotice: View {
    @Environment(\.permissionMissing) private var missing

    var body: some View {
        if missing {
            Section {
                NoticeRow(symbol: "lock.shield.fill", color: .orange, title: "Accessibility permission needed",
                          detail: "Shortcuts, mouse buttons and window management stay off until HyperSpace is allowed in Privacy & Security → Accessibility.",
                          button: "Open System Settings…") { Permissions.openSettings() }
            }
        }
    }
}

/// A caption under a section, styled the same on every page.
struct SectionFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Label of the add buttons and menus at the end of a list: the icon in the accent color,
/// the text in the primary one.
struct AddLabel: View {
    let title: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: "plus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
        }
    }
}
