import SwiftUI

// The shortcut caps and their grid, shared by the Workspaces, Window Rules and Shortcuts pages.

/// Rows of shortcuts in aligned columns: a first column, one column per caption and, when
/// `trailing` is set, a flexible gap and then that room (a remove button). Rows with a trailing
/// column put a `Spacer(minLength: 0)` cell before it, so the button sits at the right edge.
struct ShortcutGrid<Rows: View>: View {
    let columns: [String]
    var leading = ""
    /// Caption of a column after the shortcuts (rows then add that cell), if any.
    var after: String?
    var trailing: CGFloat = 0
    @ViewBuilder let rows: Rows

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            // Styled cell by cell: a modifier on the GridRow itself would make it one wide cell.
            GridRow {
                ColumnCaption(leading)
                ForEach(columns, id: \.self) { title in
                    ColumnCaption(title).frame(width: ShortcutCap.width, alignment: .leading)
                }
                if let after { ColumnCaption(after) }
                if trailing > 0 {
                    Spacer(minLength: 0)
                    Color.clear.frame(width: trailing, height: 1)
                }
            }
            rows
        }
        .padding(.vertical, 2)
    }
}

/// The small gray caption over a column of a grid, or before a cap on a line of its own.
struct ColumnCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A key cap showing a shortcut; clicking it records a new one. A slot on its right holds the
/// warning when the same keys are used twice, and stays when there is none, so caps line up.
///
/// It takes values, not the model: a page has up to about 30 caps, and each one observing a
/// whole model would redraw all of them on any change (a keystroke in a workspace name).
/// The page observes the model and hands each cap what it shows; a cap whose values did not
/// change is skipped (`Equatable`), label parsing included.
struct ShortcutCap: View, Equatable {
    static let badgeWidth: CGFloat = 16
    static let spacing: CGFloat = 6
    /// The whole width, cap and warning slot.
    static let width = Metrics.shortcutCapWidth + spacing + badgeWidth

    /// What the shortcut does, for VoiceOver ("Show workspace web", "Focus left").
    let name: String
    let keys: String
    let recording: Bool
    let duplicate: Bool
    /// Starts or stops recording this cap's field; the same for a given field.
    let toggle: () -> Void

    /// `store`: what the window pages share, which knows the cap being recorded and the
    /// shortcuts used twice. The page building the cap observes both (`capture`, `conflicts`).
    init(store: TilingModel, name: String, keys: String, field: TilingModel.Field) {
        self.name = name
        self.keys = keys
        recording = store.capturing == field
        duplicate = store.isDuplicate(keys)
        toggle = { [weak store] in store?.toggleCapture(field) }
    }

    /// The cap of a window shortcut, by action.
    init(store: TilingModel, name: String, action: String) {
        self.init(store: store, name: name, keys: store.shortcuts.keys(for: action), field: .shortcut(action))
    }

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.keys == b.keys && a.recording == b.recording && a.duplicate == b.duplicate
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            KeyCap(label: name, text: recording ? Wording.pressKeys : (keys.isEmpty ? "None" : RemapTarget.label(keys)),
                   width: Metrics.shortcutCapWidth, placeholder: keys.isEmpty, active: recording, action: toggle)
            ZStack {
                Color.clear.frame(width: Self.badgeWidth, height: 1)
                WarningBadge(text: duplicate ? "This shortcut is used more than once: only the last one works" : nil)
            }
        }
    }
}
