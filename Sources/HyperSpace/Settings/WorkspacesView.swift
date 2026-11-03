import SwiftUI

/// The Workspaces page: the workspaces with their two shortcuts, and the apps that open in one.
struct WorkspacesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHero(page: .workspaces)
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                if model.workspaces.isEmpty {
                    EmptyRow(symbol: "square.stack.3d.up", text: "No workspaces: every window shares one")
                } else {
                    ShortcutGrid(columns: ["Show workspace", "Move window here"], leading: "Name", trailing: RemoveButton.width) {
                        ForEach(model.workspaces) { workspace in
                            GridRow {
                                TextField("Name", text: Binding(get: { workspace.name }, set: { model.rename(workspace.id, to: $0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .labelsHidden()
                                    .frame(width: 120)
                                ShortcutCap(model: model, keys: workspace.switchKeys, field: .switchKeys(workspace.id))
                                ShortcutCap(model: model, keys: workspace.moveKeys, field: .moveKeys(workspace.id))
                                Spacer(minLength: 0)
                                RemoveButton { model.removeWorkspace(workspace.id) }
                            }
                        }
                    }
                }
            } header: {
                SectionHeader(title: "Workspaces") {
                    AddButton(title: "Add Workspace") { model.addWorkspace() }
                }
            } footer: {
                SettingsFooter(
                    hint: "Windows of the other workspaces are parked out of sight. They come back when you switch, quit or turn tiling off.",
                    error: model.saveError
                )
            }

            Section {
                if model.assignments.isEmpty {
                    EmptyRow(symbol: "app.badge", text: "Apps open in the workspace you are on")
                }
                ForEach(model.assignments) { rule in
                    HStack(spacing: 10) {
                        AppLabel(bundleID: rule.app)
                        Spacer(minLength: 12)
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
            } header: {
                SectionHeader(title: "App Rules") {
                    AddMenu(title: "Add App") {
                        ForEach(model.assignmentCandidates, id: \.bundleID) { app in
                            Button(app.name) { model.addAssignment(app.bundleID) }
                        }
                        Divider()
                        Button("Other App…") { model.chooseAppForAssignment() }
                    }
                    .disabled(model.workspaces.isEmpty)
                    .help(model.workspaces.isEmpty ? "Add a workspace first" : "Open an app's windows in a workspace")
                }
            } footer: {
                SectionFooter("New windows of these apps open in their workspace.")
            }
        }
        .formStyle(.grouped)
    }
}
