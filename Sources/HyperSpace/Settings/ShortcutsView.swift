import SwiftUI

/// The Shortcuts page: focus, move, resize, displays and the rest. Paired actions (focus and
/// move in the same direction) share a row, under a caption per column.
struct ShortcutsView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHero(page: .shortcuts)
            PermissionNotice()
            TilingOffNotice(model: model)

            ForEach(TilingModel.pairedShortcuts, id: \.title) { group in
                Section {
                    ShortcutGrid(columns: [group.columns.0, group.columns.1], leading: group.leading) {
                        ForEach(group.rows, id: \.title) { row in
                            GridRow {
                                Text(row.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ShortcutCap(model: model, action: row.actions.0)
                                ShortcutCap(model: model, action: row.actions.1)
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }

            ForEach(TilingModel.singleShortcuts, id: \.group) { group in
                Section {
                    ForEach(group.items, id: \.action) { item in
                        LabeledContent(item.title) {
                            ShortcutCap(model: model, action: item.action)
                        }
                    }
                } header: {
                    Text(group.group)
                } footer: {
                    if group.group == TilingModel.singleShortcuts.last?.group {
                        SettingsFooter(hint: "Click a shortcut and press the keys. Esc cancels, Delete clears it.",
                                       error: model.saveError)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Rows of shortcuts in aligned columns: a first column, one column per caption and, when
/// `trailing` is set, a flexible gap and then that room (a remove button). Rows with a trailing
/// column put a `Spacer(minLength: 0)` cell before it, so the button sits at the right edge.
struct ShortcutGrid<Rows: View>: View {
    let columns: [String]
    var leading = ""
    /// Caption of a column after the shortcuts (rows then add that cell), if any.
    var after: String?
    var trailing: CGFloat = 0
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            // Styled cell by cell: a modifier on the GridRow itself would make it one wide cell.
            GridRow {
                caption(leading)
                ForEach(columns, id: \.self) { title in
                    caption(title).frame(width: ShortcutCap.width, alignment: .leading)
                }
                if let after { caption(after) }
                if trailing > 0 {
                    Spacer(minLength: 0)
                    Color.clear.frame(width: trailing, height: 1)
                }
            }
            rows()
        }
        .padding(.vertical, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A key cap showing a shortcut; clicking it records a new one. A slot on its right holds the
/// warning when the same keys are used twice, and stays when there is none, so caps line up.
struct ShortcutCap: View {
    static let capWidth: CGFloat = 112
    static let badgeWidth: CGFloat = 16
    static let spacing: CGFloat = 6
    /// The whole width, cap and warning slot.
    static let width = capWidth + spacing + badgeWidth

    @ObservedObject var model: TilingModel
    let keys: String
    let field: TilingModel.Field

    init(model: TilingModel, keys: String, field: TilingModel.Field) {
        self.model = model
        self.keys = keys
        self.field = field
    }

    /// The cap of a window shortcut, by action.
    init(model: TilingModel, action: String) {
        self.init(model: model, keys: model.shortcuts.first { $0.action == action }?.keys ?? "", field: .shortcut(action))
    }

    var body: some View {
        let recording = model.capturing == field
        HStack(spacing: Self.spacing) {
            KeyCap(text: recording ? "Press keys…" : (keys.isEmpty ? "None" : RemapTarget.label(keys)),
                   width: Self.capWidth, placeholder: keys.isEmpty, active: recording) {
                model.toggleCapture(field)
            }
            ZStack {
                Color.clear.frame(width: Self.badgeWidth, height: 1)
                WarningBadge(text: model.isDuplicate(keys) ? "This shortcut is used more than once: only the last one works" : nil)
            }
        }
    }
}
