import SwiftUI

/// The Workspaces page: the workspaces with their two shortcuts, and the apps that open in one.
struct WorkspacesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        let screens = model.screens
        let names = model.workspaces.map(\.name)
        Form {
            PageHero(page: .workspaces)
            PermissionNotice()
            SaveErrorNotice(status: model.saveStatus)
            TilingOffNotice(model: model)

            Section {
                if model.workspaces.isEmpty {
                    EmptyRow(symbol: "square.stack.3d.up", text: "No workspaces: every window shares one")
                } else {
                    // Side by side when the page is wide enough; otherwise each workspace on two
                    // lines (name, display; then its shortcuts), so the page never gets wider than the window.
                    ViewThatFits(in: .horizontal) {
                        ShortcutGrid(columns: ["Show workspace", "Move window here"], leading: "Name", after: "Display",
                                     trailing: RemoveButton.width) {
                            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                                GridRow {
                                    nameField(workspace, at: index, names: names)
                                        .frame(width: 120)
                                    ShortcutCap(model: model, keys: workspace.switchKeys, field: .switchKeys(workspace.id))
                                        .equatable()
                                    ShortcutCap(model: model, keys: workspace.moveKeys, field: .moveKeys(workspace.id))
                                        .equatable()
                                    displayPicker(workspace, screens: screens, alignment: .leading)
                                    Spacer(minLength: 0)
                                    RemoveButton { model.askToRemoveWorkspace(workspace.id) }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { index, workspace in
                                if index > 0 { Divider() }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 10) {
                                        nameField(workspace, at: index, names: names)
                                            .frame(maxWidth: 160)
                                        Spacer(minLength: 0)
                                        displayPicker(workspace, screens: screens, alignment: .trailing)
                                        RemoveButton { model.askToRemoveWorkspace(workspace.id) }
                                    }
                                    HStack(spacing: 10) {
                                        caption("Show")
                                        ShortcutCap(model: model, keys: workspace.switchKeys, field: .switchKeys(workspace.id))
                                            .equatable()
                                        caption("Move here")
                                        ShortcutCap(model: model, keys: workspace.moveKeys, field: .moveKeys(workspace.id))
                                            .equatable()
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                SectionHeader(title: "Workspaces") {
                    AddButton(title: "Add Workspace") { model.addWorkspace() }
                }
            } footer: {
                SectionFooter("Windows of the other workspaces are parked out of sight. They come back when you switch, quit or turn tiling off. A workspace pinned to a display always shows there; with that display unplugged it goes back to its usual one. " + ShortcutRecorder.hint)
            }

            Section {
                if model.assignments.isEmpty {
                    EmptyRow(symbol: "app.badge", text: "No app rules: apps open in the workspace you are on")
                }
                ForEach(model.assignments) { rule in
                    AppRuleRow(app: rule.app, remove: { model.removeAssignment(rule.id) }) {
                        Picker("Workspace", selection: Binding(get: { rule.workspace }, set: { if let id = $0 { model.setAssignment(rule.id, workspace: id) } })) {
                            ForEach(model.workspaces) { workspace in
                                Text(workspace.name).tag(Optional(workspace.id))
                            }
                            if rule.workspace == nil {
                                Text("\(rule.text) (no such workspace)").tag(UUID?.none)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
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
        .confirmationDialog(model.removal.map { "Remove the workspace “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { model.removal != nil }, set: { if !$0 { model.cancelRemoval() } }),
                            titleVisibility: .visible, presenting: model.removal) { _ in
            Button("Remove Workspace", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
        } message: { removal in
            Text("These go with it:\n" + removal.losses.map { "• \($0)" }.joined(separator: "\n"))
        }
    }
}

extension WorkspacesView {
    private func nameField(_ workspace: TilingModel.Workspace, at index: Int, names: [String]) -> some View {
        WorkspaceNameField(draft: model.nameDraft(for: workspace), saved: workspace.name,
                           others: Set(names.enumerated().filter { $0.offset != index }.map(\.element)),
                           typed: model.nameTyped)
    }

    /// At most 160 points wide: a long display name (one not connected, say) is truncated
    /// rather than widening the page.
    private func displayPicker(_ workspace: TilingModel.Workspace, screens: [ScreenInfo],
                               alignment: Alignment) -> some View {
        Picker("Display", selection: Binding(get: { workspace.display },
                                             set: { model.setDisplay($0, for: workspace.id) })) {
            ForEach(model.displayOptions(for: workspace, screens: screens), id: \.self) { option in
                if option.startsGroup { Divider() }
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 160, alignment: alignment)
        .help("Pin the workspace to a display: by position (whichever monitor is second or third) or a monitor by name. It shows there while that display is connected")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// A workspace's name, as typed, with a warning when it cannot be saved. It observes its own
/// draft, so a keystroke redraws this field, not the page.
private struct WorkspaceNameField: View {
    @ObservedObject var draft: NameDraft
    /// The name saved, kept while the typed one is not valid.
    let saved: String
    /// The other workspaces' names.
    let others: Set<String>
    let typed: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("Name", text: Binding(get: { draft.text }, set: { draft.text = $0; typed() }))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            WarningBadge(text: TilingModel.nameWarning(typed: draft.text, saved: saved, others: others))
        }
    }
}
