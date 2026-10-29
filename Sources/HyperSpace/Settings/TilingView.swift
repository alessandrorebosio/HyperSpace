import SwiftUI

/// Tiling on or off, layout, spacing.
struct TilingView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PermissionNotice()

            Section {
                Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
                    Text("Tile windows")
                    Text("Arrange the windows of each workspace side by side, without overlaps.")
                }
            }

            Section {
                LayoutChooser(selection: model.layout, gap: model.gap, padding: model.padding) { model.setLayout($0) }
                Stepper(value: Binding(get: { model.gap }, set: { model.setGap($0) }), in: 0...64, step: 2) {
                    LabeledContent("Gap between windows", value: "\(model.gap) pt")
                }
                Stepper(value: Binding(get: { model.padding }, set: { model.setPadding($0) }), in: 0...64, step: 2) {
                    LabeledContent("Margin around the screen", value: "\(model.padding) pt")
                }
            } header: {
                Text("Layout")
            } footer: {
                SettingsFooter(hint: "Next layout in Shortcuts cycles through them on the fly.", error: model.saveError)
            }
            .disabled(!model.enabled)

            Section {
                Toggle(isOn: Binding(get: { model.mouseFollowsFocus }, set: { model.setMouseFollowsFocus($0) })) {
                    Text("Pointer follows focus")
                    Text("When the focus moves to another display, the pointer goes there too.")
                }
            } header: {
                Text("Focus")
            }
            .disabled(!model.enabled)
        }
        .formStyle(.grouped)
    }
}

/// Workspaces with their shortcuts, and the apps that open in one.
struct WorkspacesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                if !model.workspaces.isEmpty {
                    HStack(spacing: 10) {
                        Text("Name").frame(width: 90, alignment: .leading)
                        ShortcutColumnHeader(title: "Show workspace")
                        ShortcutColumnHeader(title: "Move window here")
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.workspaces) { workspace in
                    WorkspaceRow(model: model, workspace: workspace)
                }
                Button {
                    model.addWorkspace()
                } label: {
                    AddLabel(title: "Add Workspace")
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
                    AddLabel(title: "Add App")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Color.accentColor)
                .disabled(model.workspaces.isEmpty)
            } header: {
                Text("App Rules")
            } footer: {
                SectionFooter("New windows of these apps open in their workspace; opening the app takes you there.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Apps and windows kept out of the tiling, and scratchpad apps.
struct WindowRulesView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                if model.floating.isEmpty && model.floatingWindows.isEmpty {
                    Text("Every window is tiled").foregroundStyle(.secondary)
                }
                ForEach(model.floating, id: \.self) { bundleID in
                    HStack {
                        AppLabel(bundleID: bundleID)
                        Text("All windows").foregroundStyle(.secondary)
                        Spacer()
                        RemoveButton { model.removeFloating(bundleID) }
                    }
                }
                ForEach(Array(model.floatingWindows.enumerated()), id: \.offset) { _, rule in
                    HStack {
                        if let app = rule.app { AppLabel(bundleID: app) } else { Text("Any app") }
                        Text("Title contains “\(rule.title)”").foregroundStyle(.secondary)
                        Spacer()
                        RemoveButton { model.removeFloatingWindow(rule) }
                    }
                }
                HStack {
                    Picker("App", selection: Binding(get: { model.newFloatingApp }, set: { model.newFloatingApp = $0 })) {
                        Text("Any app").tag(String?.none)
                        ForEach(TilingModel.runningApps, id: \.bundleID) { app in
                            Text(app.name).tag(Optional(app.bundleID))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    TextField("Title", text: Binding(get: { model.newFloatingTitle }, set: { model.newFloatingTitle = $0 }),
                              prompt: Text("Title contains… (optional)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addFloatingRule() }
                    Button("Add") { model.addFloatingRule() }
                        .disabled(!model.canAddFloatingRule)
                }
            } header: {
                Text("Floating")
            } footer: {
                SettingsFooter(hint: "Floating windows are never tiled: they keep their own size and position. Pick an app to float all its windows, or add a title to float only some, like an app's settings or a dialog (case doesn't matter).",
                               error: model.saveError)
            }

            Section {
                if !model.scratchpadApps.isEmpty {
                    HStack(spacing: 10) {
                        Spacer()
                        ShortcutColumnHeader(title: "Show / hide")
                        ShortcutColumnHeader(title: "To tiling and back")
                        Color.clear.frame(width: RemoveButton.width, height: 1)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.scratchpadApps) { pad in
                    HStack(spacing: 10) {
                        AppLabel(bundleID: pad.bundleID)
                        Spacer()
                        ShortcutCap(model: model, keys: pad.toggleKeys, field: .shortcut(pad.toggleAction))
                        ShortcutCap(model: model, keys: pad.tileKeys, field: .shortcut(pad.tileAction))
                        RemoveButton { model.removeScratchpadApp(pad.bundleID) }
                    }
                }
                Menu {
                    ForEach(model.scratchpadCandidates, id: \.bundleID) { app in
                        Button(app.name) { model.addScratchpadApp(app.bundleID) }
                    }
                    Divider()
                    Button("Choose App…") { model.chooseAppForScratchpad() }
                } label: {
                    AddLabel(title: "Add App")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .tint(Color.accentColor)
            } header: {
                Text("Scratchpad Apps")
            } footer: {
                SectionFooter("Show / hide puts the app centered above the other windows, out of the tiling, opening it if needed; pressed again it hides it. To tiling and back moves its window into the workspace you are on, and again into the scratchpad.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Shortcuts for focus, moving, resizing and layouts. Paired actions share a row.
struct TilingShortcutsView: View {
    @ObservedObject var model: TilingModel

    private static let directions = [("Left", "left"), ("Down", "down"), ("Up", "up"), ("Right", "right")]

    var body: some View {
        Form {
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
                ColumnHeaders(titles: ["Focus", "Move window"])
                ForEach(Self.directions, id: \.1) { name, direction in
                    PairRow(model: model, title: name, actions: ("focus \(direction)", "swap \(direction)"))
                }
            } header: {
                Text("Focus & Move")
            }

            Section {
                ColumnHeaders(titles: ["Smaller", "Larger"])
                PairRow(model: model, title: "Width", actions: ("resize width -50", "resize width +50"))
                PairRow(model: model, title: "Height", actions: ("resize height -50", "resize height +50"))
            } header: {
                Text("Resize")
            }

            ForEach(TilingModel.shortcutActions.dropFirst(2), id: \.group) { group in
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
                        SettingsFooter(hint: "Click a shortcut and press the keys. Esc cancels, Delete clears.",
                                       error: model.saveError)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Captions over the shortcut columns of the rows below.
private struct ColumnHeaders: View {
    let titles: [String]

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            ForEach(titles, id: \.self) { ShortcutColumnHeader(title: $0) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Two related shortcuts on one row, like focus and move in the same direction.
private struct PairRow: View {
    @ObservedObject var model: TilingModel
    let title: String
    let actions: (String, String)

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer()
            cap(actions.0)
            cap(actions.1)
        }
    }

    private func cap(_ action: String) -> some View {
        ShortcutCap(model: model, keys: model.shortcuts.first { $0.action == action }?.keys ?? "", field: .shortcut(action))
    }
}

/// Shown on the window pages while tiling is off: the settings are kept but do nothing.
private struct TilingOffNotice: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        if !model.enabled {
            Section {
                NoticeRow(symbol: "pause.circle", color: .secondary, title: "Tiling is off",
                          detail: "These settings are kept and apply as soon as tiling is on.",
                          button: "Turn On") { model.setEnabled(true) }
            }
        }
    }
}

/// The layouts as thumbnails; the gap and margin are drawn to scale with the settings.
private struct LayoutChooser: View {
    let selection: LayoutKind
    let gap: Int
    let padding: Int
    let onSelect: (LayoutKind) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(LayoutKind.allCases, id: \.self) { kind in
                let selected = kind == selection
                Button { onSelect(kind) } label: {
                    VStack(spacing: 6) {
                        LayoutThumbnail(kind: kind, gap: gap, padding: padding, selected: selected)
                            .frame(width: 96, height: 60)
                        Text(kind.rawValue.capitalized)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.help(kind))
                .accessibilityLabel(kind.rawValue.capitalized)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private static func help(_ kind: LayoutKind) -> String {
        switch kind {
        case .tall: return "Main window on the left, the others stacked on the right"
        case .wide: return "Main window on top, the others side by side below"
        case .columns: return "One column per window"
        case .monocle: return "Every window full screen, one above the other"
        }
    }
}

private struct LayoutThumbnail: View {
    let kind: LayoutKind
    let gap: Int
    let padding: Int
    let selected: Bool

    var body: some View {
        // Exaggerated so a few points are still visible at this size.
        let scale: CGFloat = 0.15
        let inset = padding == 0 ? 0 : max(1, CGFloat(padding) * scale)
        let spacing = gap == 0 ? 0 : max(1, CGFloat(gap) * scale)
        Canvas { context, size in
            let area = CGRect(origin: .zero, size: size).insetBy(dx: inset + 3, dy: inset + 3)
            let frames = Layout.frames(kind, weights: kind == .monocle ? [1] : [1, 1, 1], in: area, gap: spacing, ratio: 0.55)
            for (index, frame) in frames.enumerated() {
                let tile = Path(roundedRect: frame, cornerRadius: 2.5)
                context.fill(tile, with: .color(Color.accentColor.opacity(index == 0 ? 0.55 : 0.3)))
                context.stroke(tile, with: .color(Color.accentColor.opacity(0.8)), lineWidth: 0.75)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
        )
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
        }
        .help(bundleID)
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
    static let capWidth: CGFloat = 130
    static let badgeWidth: CGFloat = 16
    static let spacing: CGFloat = 6

    @ObservedObject var model: TilingModel
    let keys: String
    let field: TilingModel.Field

    var body: some View {
        HStack(spacing: Self.spacing) {
            KeyCap(text: model.capturing == field ? "Press keys…" : (keys.isEmpty ? "None" : RemapTarget.label(keys)),
                   width: Self.capWidth, placeholder: keys.isEmpty, active: model.capturing == field) {
                model.capturing == field ? model.stopCapture() : model.startCapture(field)
            }
            // The slot stays when there is no warning (an empty view takes no space), so
            // caps and their column headers line up.
            ZStack {
                Color.clear.frame(width: Self.badgeWidth, height: 1)
                WarningBadge(text: model.isDuplicate(keys) ? "This shortcut is used more than once" : nil)
            }
        }
    }
}

/// A column caption laid out like a ShortcutCap, centered over the cap.
private struct ShortcutColumnHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: ShortcutCap.spacing) {
            Text(title).lineLimit(1).frame(width: ShortcutCap.capWidth)
            Color.clear.frame(width: ShortcutCap.badgeWidth, height: 1)
        }
    }
}
