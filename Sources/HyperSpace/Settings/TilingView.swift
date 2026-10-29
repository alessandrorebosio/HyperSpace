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
                Toggle(isOn: Binding(get: { model.mouseFollowsFocus }, set: { model.setMouseFollowsFocus($0) })) {
                    Text("Pointer follows focus")
                    Text("When the focus moves to another display, the pointer goes there too.")
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

            Section {
                if model.assignments.isEmpty {
                    Text("Apps open wherever you are").foregroundStyle(.secondary)
                }
                ForEach(model.assignments) { rule in
                    HStack {
                        AppLabel(bundleID: rule.app)
                        Spacer()
                        Picker("Workspace", selection: Binding(get: { rule.workspace }, set: { model.setAssignment(rule.id, workspace: $0) })) {
                            ForEach(model.workspaces.map(\.name), id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        RemoveButton { model.removeAssignment(rule.id) }
                    }
                }
                Menu {
                    ForEach(model.assignmentCandidates, id: \.bundleID) { app in
                        Button(app.name) { model.addAssignment(app.bundleID) }
                    }
                    Divider()
                    Button("Other App…") { model.chooseAppForAssignment() }
                } label: {
                    Label("Add App", systemImage: "plus.circle.fill").foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.workspaces.isEmpty)
            } header: {
                Text("App Rules")
            } footer: {
                Text("New windows of these apps open in their workspace; opening the app takes you there.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.floating.isEmpty {
                    Text("Every app is tiled").foregroundStyle(.secondary)
                }
                ForEach(model.floating, id: \.self) { bundleID in
                    HStack {
                        AppLabel(bundleID: bundleID)
                        Spacer()
                        RemoveButton { model.removeFloating(bundleID) }
                    }
                }
                Menu {
                    ForEach(model.floatingCandidates, id: \.bundleID) { app in
                        Button(app.name) { model.addFloating(app.bundleID) }
                    }
                } label: {
                    Label("Add App", systemImage: "plus.circle.fill").foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } header: {
                Text("Floating Apps")
            } footer: {
                Text("Windows of these apps are never tiled: they keep their own size and position.")
                    .font(.caption).foregroundStyle(.secondary)
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

/// App icon, name and bundle id.
private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        HStack {
            if let icon = TilingModel.appIcon(bundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(TilingModel.appName(bundleID))
            Text(bundleID).font(.caption).foregroundStyle(.tertiary)
        }
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
            KeyCap(text: model.capturing == field ? "Press keys…" : (keys.isEmpty ? "None" : RemapTarget.label(keys)),
                   width: 150, placeholder: keys.isEmpty, active: model.capturing == field) {
                model.capturing == field ? model.stopCapture() : model.startCapture(field)
            }
            WarningBadge(text: model.isDuplicate(keys) ? "This shortcut is used more than once" : nil)
        }
    }
}
