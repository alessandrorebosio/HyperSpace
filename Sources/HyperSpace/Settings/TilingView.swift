import SwiftUI

struct TilingView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            Section {
                Toggle("Tile windows", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                Picker("Layout", selection: Binding(get: { model.layout }, set: { model.setLayout($0) })) {
                    ForEach(LayoutKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue.capitalized).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Stepper(value: Binding(get: { model.gap }, set: { model.setGap($0) }), in: 0...64, step: 2) {
                    LabeledContent("Gap between windows", value: "\(model.gap) pt")
                }
                Stepper(value: Binding(get: { model.padding }, set: { model.setPadding($0) }), in: 0...64, step: 2) {
                    LabeledContent("Margin around the screen", value: "\(model.padding) pt")
                }
            } header: {
                Text("Tiling")
            }

            Section {
                if !model.workspaces.isEmpty {
                    HStack(spacing: 10) {
                        Text("Name").frame(width: 90, alignment: .leading)
                        Text("Show workspace").frame(width: 150, alignment: .leading)
                        Text("Move window here").frame(width: 150, alignment: .leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.workspaces) { workspace in
                    WorkspaceRow(model: model, workspace: workspace)
                }
                Button {
                    model.addWorkspace()
                } label: {
                    Label("Add Workspace", systemImage: "plus.circle.fill").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Workspaces")
            } footer: {
                SettingsFooter(
                    hint: "Windows of other workspaces are parked out of sight and come back when you switch, quit or turn tiling off. ⌘Tab to a window of another workspace switches to it.",
                    error: model.saveError
                )
            }

            ForEach(TilingModel.shortcutActions, id: \.group) { group in
                Section {
                    ForEach(group.items, id: \.action) { item in
                        if let shortcut = model.shortcuts.first(where: { $0.action == item.action }) {
                            ShortcutRow(model: model, shortcut: shortcut)
                        }
                    }
                } header: {
                    Text(group.group)
                } footer: {
                    if group.group == TilingModel.shortcutActions.last?.group {
                        Text("Click a shortcut and press the keys. Esc cancels, Delete clears.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var model: TilingModel
    let workspace: TilingModel.Workspace

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: Binding(get: { workspace.name }, set: { model.rename(workspace.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 90)
            ShortcutCap(model: model, keys: workspace.switchKeys, field: .switchKeys(workspace.id))
            ShortcutCap(model: model, keys: workspace.moveKeys, field: .moveKeys(workspace.id))
            Spacer()
            RemoveButton { model.removeWorkspace(workspace.id) }
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var model: TilingModel
    let shortcut: TilingModel.Shortcut

    var body: some View {
        LabeledContent(shortcut.title) {
            ShortcutCap(model: model, keys: shortcut.keys, field: .shortcut(shortcut.action))
        }
    }
}

/// A key cap showing a shortcut; clicking it records a new one.
private struct ShortcutCap: View {
    @ObservedObject var model: TilingModel
    let keys: String
    let field: TilingModel.Field

    var body: some View {
        HStack(spacing: 6) {
            KeyCap(text: model.capturing == field ? "Press keys…" : (keys.isEmpty ? "None" : KeyCombo.label(keys)),
                   width: 150, placeholder: keys.isEmpty, active: model.capturing == field) {
                model.capturing == field ? model.stopCapture() : model.startCapture(field)
            }
            WarningBadge(text: model.isDuplicate(keys) ? "This shortcut is used more than once" : nil)
        }
    }
}
