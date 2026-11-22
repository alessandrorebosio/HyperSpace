import SwiftUI

/// The Workspaces page: the workspaces with their two shortcuts, and the apps that open in one.
struct WorkspacesView: View {
    /// What the window pages share: the save status, the shortcut caps' recording and duplicates.
    let store: TilingModel
    @ObservedObject var model: WorkspacesModel
    /// The cap being recorded and the shortcuts used twice: a change of either redraws the caps.
    @ObservedObject var capture: FieldCapture<TilingModel.Field>
    @ObservedObject var conflicts: ShortcutConflicts
    /// The apps running, for the app menu.
    @ObservedObject var apps: RunningApps

    var body: some View {
        // Worked out once for both layouts of the list: each row's other names and display choices.
        let rows = WorkspaceRow.rows(model: model, store: store)
        Form {
            PageHero(page: .workspaces)
            PermissionNotice()
            SaveErrorNotice(status: store.saveStatus)
            TilingOffNotice(model: store.options)

            Section {
                if rows.isEmpty {
                    EmptyRow(symbol: "square.stack.3d.up", text: "No workspaces: every window shares one")
                } else {
                    // Side by side when the page is wide enough; otherwise each workspace on two
                    // lines (name, display; then its shortcuts), so the page never gets wider than the window.
                    ViewThatFits(in: .horizontal) {
                        ShortcutGrid(columns: ["Show workspace", "Move window here"], leading: "Name", after: "Display",
                                     trailing: RemoveButton.width) {
                            ForEach(rows) { $0 }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(rows) { row in
                                if !row.isFirst { Divider() }
                                row.compacted
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
                    AddAppMenu(candidates: apps.candidates(excluding: model.assignments.map(\.app)), add: model.addAssignment) {
                        if let bundleID = SettingsPanels.chooseApp(prompt: "Assign") { model.addAssignment(bundleID) }
                    }
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

/// One workspace: its name, its two shortcuts, its display and its remove button. As a row of
/// the page's grid, or `compact`, on two lines (name, display and remove; then the shortcuts)
/// when the window is too narrow for the grid.
private struct WorkspaceRow: View, Identifiable {
    let model: WorkspacesModel
    let workspace: TilingModel.Workspace
    let draft: NameDraft
    /// The other workspaces' names.
    let others: Set<String>
    let displays: [TilingModel.DisplayOption]
    /// The two shortcut caps, built by the page with what they show (recording, duplicate):
    /// a change of either redraws the row.
    let switchCap: ShortcutCap
    let moveCap: ShortcutCap
    let isFirst: Bool
    var compact = false

    var id: UUID { workspace.id }

    /// The same row on two lines.
    var compacted: WorkspaceRow {
        var row = self
        row.compact = true
        return row
    }

    /// A row per workspace, each with what it needs worked out once per redraw of the page.
    static func rows(model: WorkspacesModel, store: TilingModel) -> [WorkspaceRow] {
        let names = model.workspaces.map(\.name)
        let screens = model.screens
        return model.workspaces.enumerated().map { index, workspace in
            WorkspaceRow(model: model, workspace: workspace, draft: model.nameDraft(for: workspace),
                         others: Set(names.enumerated().filter { $0.offset != index }.map(\.element)),
                         displays: TilingModel.displayOptions(pin: workspace.display, screens: screens),
                         switchCap: ShortcutCap(store: store, name: "Show workspace \(workspace.name)",
                                                keys: workspace.switchKeys, field: .switchKeys(workspace.id)),
                         moveCap: ShortcutCap(store: store, name: "Move window to workspace \(workspace.name)",
                                              keys: workspace.moveKeys, field: .moveKeys(workspace.id)),
                         isFirst: index == 0)
        }
    }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    nameField.frame(maxWidth: Metrics.nameMaxWidth)
                    Spacer(minLength: 0)
                    displayPicker(alignment: .trailing)
                    removeButton
                }
                HStack(spacing: 10) {
                    ColumnCaption("Show")
                    switchCap.equatable()
                    ColumnCaption("Move here")
                    moveCap.equatable()
                }
            }
        } else {
            GridRow {
                nameField.frame(width: Metrics.nameWidth)
                switchCap.equatable()
                moveCap.equatable()
                displayPicker(alignment: .leading)
                Spacer(minLength: 0)
                removeButton
            }
        }
    }

    private var nameField: some View {
        WorkspaceNameField(draft: draft, saved: workspace.name, others: others, typed: model.nameTyped)
    }

    private var removeButton: some View {
        RemoveButton(what: "the workspace \(workspace.name)") { model.askToRemoveWorkspace(workspace.id) }
    }

    /// At most `Metrics.displayMenuWidth` wide: a long display name (one not connected, say) is
    /// truncated rather than widening the page.
    private func displayPicker(alignment: Alignment) -> some View {
        Picker("Display of workspace \(workspace.name)",
               selection: Binding(get: { workspace.display }, set: { model.setDisplay($0, for: workspace.id) })) {
            ForEach(displays, id: \.self) { option in
                if option.startsGroup { Divider() }
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .frame(maxWidth: Metrics.displayMenuWidth, alignment: alignment)
        .help("Pin the workspace to a display: by position (whichever monitor is second or third) or a monitor by name. It shows there while that display is connected")
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
            TextField("Name of workspace \(saved)", text: Binding(get: { draft.text }, set: { draft.text = $0; typed() }),
                      prompt: Text("Name"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            WarningBadge(text: TilingModel.nameWarning(typed: draft.text, saved: saved, others: others))
        }
    }
}
