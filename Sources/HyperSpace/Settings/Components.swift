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

/// A key drawn as a key cap. Clicking it starts capturing; while capturing it is
/// outlined in the accent color.
struct KeyCap: View {
    let text: String
    var symbol: String?
    /// Fixed width keeps arrows and caps aligned from row to row.
    var width: CGFloat?
    var placeholder = false
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(text).lineLimit(1)
            }
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(active ? Color.accentColor : (placeholder ? Color.secondary : Color.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(width: width.map { $0 - 20 })
            .frame(minWidth: 36)
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
            Image(systemName: "chevron.down.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
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
