import SwiftUI

/// The Shortcuts page: focus, move, resize, displays and the rest. Paired actions (focus and
/// move in the same direction) share a row, under a caption per column.
struct ShortcutsView: View {
    /// What the window pages share: the save status, the shortcut caps' recording and duplicates.
    let store: TilingModel
    @ObservedObject var model: ShortcutsModel
    /// The cap being recorded and the shortcuts used twice: a change of either redraws the caps.
    @ObservedObject var capture: FieldCapture<TilingModel.Field>
    @ObservedObject var conflicts: ShortcutConflicts

    var body: some View {
        Form {
            PageHero(page: .shortcuts)
            PermissionNotice()
            SaveErrorNotice(status: store.saveStatus)
            TilingOffNotice(model: store.options)

            ForEach(TilingModel.pairedShortcuts, id: \.title) { group in
                Section {
                    ShortcutGrid(columns: [group.columns.0, group.columns.1], leading: group.leading) {
                        ForEach(group.rows, id: \.title) { row in
                            GridRow {
                                Text(row.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                ShortcutCap(store: store, name: "\(group.columns.0), \(row.title.lowercased())", action: row.actions.0)
                                    .equatable()
                                ShortcutCap(store: store, name: "\(group.columns.1), \(row.title.lowercased())", action: row.actions.1)
                                    .equatable()
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
                        SettingRow(title: item.title) {
                            ShortcutCap(store: store, name: item.title, action: item.action)
                                .equatable()
                        }
                    }
                } header: {
                    Text(group.group)
                } footer: {
                    if group.group == TilingModel.singleShortcuts.last?.group {
                        SectionFooter(ShortcutRecorder.hint)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
