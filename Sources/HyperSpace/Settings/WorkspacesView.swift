import SwiftUI

/// The Workspaces page: the workspaces with their two shortcuts, and the apps that open in one.
struct WorkspacesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        let screens = model.screens
        Form {
            PageHero(page: .workspaces)
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                if model.workspaces.isEmpty {
                    EmptyRow(symbol: "square.stack.3d.up", text: "No workspaces: every window shares one")
                } else {
                    ShortcutGrid(columns: ["Show workspace", "Move window here"], leading: "Name", after: "Display",
                                 trailing: RemoveButton.width) {
                        ForEach(model.workspaces) { workspace in
                            GridRow {
                                HStack(spacing: 4) {
                                    TextField("Name", text: Binding(get: { workspace.name }, set: { model.rename(workspace.id, to: $0) }))
                                        .textFieldStyle(.roundedBorder)
                                        .labelsHidden()
                                    WarningBadge(text: model.nameWarning(for: workspace))
                                }
                                .frame(width: 140)
                                ShortcutCap(model: model, keys: workspace.switchKeys, field: .switchKeys(workspace.id))
                                    .equatable()
                                ShortcutCap(model: model, keys: workspace.moveKeys, field: .moveKeys(workspace.id))
                                    .equatable()
                                Picker("Display", selection: Binding(get: { workspace.display },
                                                                     set: { model.setDisplay($0, for: workspace.id) })) {
                                    ForEach(model.displayOptions(for: workspace, screens: screens), id: \.self) { option in
                                        Text(option.label).tag(option.value)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .help("Pin the workspace to a display: it always shows there while that display is connected")
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
                SectionFooter(
                    "Windows of the other workspaces are parked out of sight. They come back when you switch, quit or turn tiling off. A workspace pinned to a display always shows there; with that display unplugged it goes back to its usual one. Click a shortcut and press the keys: Esc cancels, Delete clears it.",
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
                        Picker("Workspace", selection: Binding(get: { rule.workspace }, set: { if let id = $0 { model.setAssignment(rule.id, workspace: id) } })) {
                            ForEach(model.workspaces) { workspace in
                                Text(workspace.savedName).tag(Optional(workspace.id))
                            }
                            if rule.workspace == nil {
                                Text("\(rule.text) (no such workspace)").tag(UUID?.none)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        RemoveButton { model.removeAssignment(rule.id) }
                    }
                }
            } header: {
                SectionHeader(title: "App Rules") {
                    AddAppMenu(candidates: model.assignmentCandidates, chooseTitle: "Other App…",
                               add: model.addAssignment, choose: model.chooseAppForAssignment)
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
