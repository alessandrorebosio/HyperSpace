import SwiftUI

/// Tiling on or off, layout, spacing.
struct TilingView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHeader()
            PermissionNotice()

            Section {
                Toggle(isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })) {
                    RowLabel("Tile windows", detail: "Off: windows stay where you put them.")
                }
            }

            Section {
                LayoutChooser(selection: model.layout, gap: model.gap, padding: model.padding,
                              peek: model.accordionPadding) { model.setLayout($0) }
                SliderRow(title: "Gap between windows",
                          value: model.gap, range: 0...64, step: 2) { model.setGap($0, commit: $1) }
                SliderRow(title: "Margin around the screen",
                          value: model.padding, range: 0...64, step: 2) { model.setPadding($0, commit: $1) }
            } header: {
                Text("Layout")
            } footer: {
                SettingsFooter(hint: "Windows stay inside the visible area, clear of the menu bar and the Dock.",
                               error: model.saveError)
            }
            .disabled(!model.enabled)

            Section {
                Toggle(isOn: Binding(get: { model.mouseFollowsFocus }, set: { model.setMouseFollowsFocus($0) })) {
                    RowLabel("Pointer follows focus", detail: "When the focus moves to another display, the pointer goes there too.")
                }
            } header: {
                Text("Focus")
            }
            .disabled(!model.enabled)

            Section {
                SliderRow(title: "Visible edges",
                          value: model.accordionPadding, range: 0...120, step: 5) { model.setAccordionPadding($0, commit: $1) }
                AccordionPreview(peek: model.accordionPadding)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Accordion")
            } footer: {
                SectionFooter("How much of the windows behind the front one shows at each side. Also used by workspaces stacked with the accordion shortcut.")
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
            PageHeader()
            PermissionNotice()
            TilingOffNotice(model: model)

            Section {
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
                    hint: "Windows of other workspaces are parked out of sight and come back when you switch, quit or turn tiling off.",
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
                .modifier(BorderlessMenu())
                .disabled(model.workspaces.isEmpty)
            } header: {
                Text("App Rules")
            } footer: {
                SectionFooter("New windows of these apps open in their workspace.")
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
            PageHeader()
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
                              prompt: Text("Title contains…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addFloatingRule() }
                    Button("Add") { model.addFloatingRule() }
                        .disabled(!model.canAddFloatingRule)
                }
            } header: {
                Text("Floating")
            } footer: {
                SettingsFooter(hint: "Floating windows keep their own size and position. Add a title to float only some windows of an app, such as its settings.",
                               error: model.saveError)
            }

            Section {
                ForEach(model.scratchpadApps) { pad in
                    ScratchpadRow(model: model, pad: pad)
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
                .modifier(BorderlessMenu())
            } header: {
                Text("Scratchpad Apps")
            } footer: {
                SectionFooter("Show / hide centers the app above the other windows. To tiling and back moves its window into the current workspace, and again into the scratchpad.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Shortcuts for focus, moving, resizing and layouts. Paired actions share a row.
struct TilingShortcutsView: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        Form {
            PageHeader()
            PermissionNotice()
            TilingOffNotice(model: model)

            ForEach(TilingModel.pairedShortcuts, id: \.title) { group in
                Section {
                    ColumnHeaders(titles: [group.columns.0, group.columns.1])
                    ForEach(group.rows, id: \.title) { row in
                        PairRow(model: model, title: row.title, actions: row.actions)
                    }
                } header: {
                    Text(group.title)
                }
            }

            ForEach(TilingModel.singleShortcuts, id: \.group) { group in
                Section {
                    ForEach(group.items, id: \.action) { item in
                        if let shortcut = model.shortcuts.first(where: { $0.action == item.action }) {
                            ShortcutRow(model: model, shortcut: shortcut)
                        }
                    }
                } header: {
                    Text(group.group)
                } footer: {
                    if group.group == TilingModel.singleShortcuts.last?.group {
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

/// A setting in points: title, a slider, and the value, like the sliders of System Settings.
private struct SliderRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// The new value, and whether it is final (the slider was released) or a drag in progress.
    let onChange: (Int, Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 12)
            // Continuous (no tick marks), rounded to `step`. Saved only on release: every save
            // reloads the config and retiles the windows.
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int(($0 / Double(step)).rounded()) * step, false) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing { onChange(value, true) }
            }
                .frame(width: 200)
                .labelsHidden()
            Text("\(value) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// Three windows as an accordion with the chosen edges, drawn to scale (a 1000 pt wide area).
private struct AccordionPreview: View {
    let peek: Int

    var body: some View {
        Canvas { context, size in
            let area = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            let scale = area.width / 1000
            let frames = Layout.accordion(count: 3, focused: 1, in: area, peek: CGFloat(peek) * scale)
            for index in [0, 2, 1] {
                let main = index == 1
                let frame = main ? frames[index] : frames[index].insetBy(dx: 0, dy: 6)
                let card = Path(roundedRect: frame, cornerRadius: 7, style: .continuous)
                var shadowed = context
                if main { shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 4, y: 1.5)) }
                shadowed.fill(card, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.fill(card, with: .color(Color.accentColor.opacity(main ? 0.85 : 0.35)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .frame(maxWidth: 360)
        .accessibilityLabel("Accordion preview with \(peek) point edges")
    }
}

/// Shown on the window pages while tiling is off: the settings are kept but do nothing.
private struct TilingOffNotice: View {
    @ObservedObject var model: TilingModel

    var body: some View {
        if !model.enabled {
            Section {
                NoticeRow(symbol: "pause.fill", color: .gray, title: "Tiling is off",
                          detail: "These settings are kept and apply as soon as tiling is on.",
                          button: "Turn On") { model.setEnabled(true) }
            }
        }
    }
}

/// The layouts as thumbnails; the gap and margin are drawn to scale with the settings. In a narrow
/// window the thumbnails shrink, and below that they wrap onto more lines.
private struct LayoutChooser: View {
    let selection: LayoutKind
    let gap: Int
    let padding: Int
    let peek: Int
    let onSelect: (LayoutKind) -> Void

    // Like the Appearance picker of System Settings: no glass of its own inside the form (the
    // grouped form already sits on the system's Liquid Glass; glass is for floating controls).
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { options(compact: false) }
            HStack(spacing: 6) { options(compact: true) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], spacing: 6) { options(compact: true) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func options(compact: Bool) -> some View {
        ForEach(LayoutKind.allCases, id: \.self) { kind in
            LayoutOption(kind: kind, selected: kind == selection, compact: compact, gap: gap, padding: padding, peek: peek) {
                onSelect(kind)
            }
            .help(Self.help(kind))
        }
    }

    private static func help(_ kind: LayoutKind) -> String {
        switch kind {
        case .tall: return "Main window on the left, the others stacked on the right"
        case .wide: return "Main window on top, the others side by side below"
        case .columns: return "One column per window"
        case .monocle: return "Every window full screen, one above the other"
        case .accordion: return "Windows stacked on top of each other, the ones behind peeking out at the sides"
        }
    }
}

/// One layout: its picture and name on a softly filled tile, ringed with the accent color when chosen.
private struct LayoutOption: View {
    let kind: LayoutKind
    let selected: Bool
    let compact: Bool
    let gap: Int
    let padding: Int
    let peek: Int
    let action: () -> Void

    private static let corner: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                LayoutThumbnail(kind: kind, gap: gap, padding: padding, peek: peek, selected: selected, compact: compact)
                    .frame(width: compact ? 60 : 84, height: compact ? 40 : 54)
                Text(kind.rawValue.capitalized)
                    .font((compact ? Font.caption : Font.callout).weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .contentShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(OptionBackground(selected: selected, corner: Self.corner))
        .accessibilityLabel(kind.rawValue.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct OptionBackground: ViewModifier {
    let selected: Bool
    let corner: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background(shape.fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
    }
}

/// A small picture of a display with the layout's windows on it. The display and the windows
/// share concentric rounded corners; the main (or focused) window is filled with the accent
/// color, the others are lighter, gray when the layout is not the chosen one. Gap and margin
/// are drawn to scale, exaggerated so a few points still show; the accordion's edges are
/// widened enough to read, and its windows behind are drawn shorter, as a stack.
private struct LayoutThumbnail: View {
    let kind: LayoutKind
    let gap: Int
    let padding: Int
    let peek: Int
    let selected: Bool
    /// The smaller thumbnail of a narrow window: gap and margin are drawn smaller too.
    let compact: Bool

    var body: some View {
        let scale: CGFloat = compact ? 0.1 : 0.15
        let inset = padding == 0 ? 0 : max(1.5, CGFloat(padding) * scale)
        let spacing = gap == 0 ? 0 : max(2.5, CGFloat(gap) * scale)
        let screenCorner: CGFloat = 9
        Canvas { context, size in
            let margin = 4 + inset
            let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            let count = kind == .monocle ? 1 : 3
            let frames = Layout.frames(kind, weights: Array(repeating: 1, count: count), in: area, gap: spacing, ratio: 0.55,
                                       focused: 1, peek: max(compact ? 8 : 12, CGFloat(peek) * 0.35))
            let order = kind == .accordion ? [0, 2, 1] : Array(frames.indices)
            let corner = max(2.5, screenCorner - margin)
            let tint = selected ? Color.accentColor : Color.secondary
            for index in order {
                let main = kind == .accordion ? index == 1 : index == 0
                let frame = kind == .accordion && !main ? frames[index].insetBy(dx: 0, dy: 5) : frames[index]
                let card = Path(roundedRect: frame, cornerRadius: corner, style: .continuous)
                if kind == .accordion {
                    // Opaque first, so the windows behind do not show through the front one.
                    var shadowed = context
                    if main { shadowed.addFilter(.shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)) }
                    shadowed.fill(card, with: .color(Color(nsColor: .windowBackgroundColor)))
                }
                context.fill(card, with: .color(tint.opacity(main ? 0.85 : 0.35)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: screenCorner, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }
}

/// App icon, name and bundle id.
private struct AppLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon = TilingModel.appIcon(bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
            }
            Text(TilingModel.appName(bundleID))
        }
        .help(bundleID)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var model: TilingModel
    let workspace: TilingModel.Workspace

    /// One line when it fits; otherwise the name on the first line and the shortcuts under it.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                nameField
                shortcuts
                Spacer(minLength: 12)
                remove.padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    nameField
                    Spacer(minLength: 12)
                    remove
                }
                shortcuts
            }
        }
    }

    private var nameField: some View {
        TextField("Name", text: Binding(get: { workspace.name }, set: { model.rename(workspace.id, to: $0) }))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 100)
    }

    private var shortcuts: some View {
        HStack(spacing: 10) {
            ShortcutField(model: model, title: "Show workspace", keys: workspace.switchKeys, field: .switchKeys(workspace.id))
            ShortcutField(model: model, title: "Move window here", keys: workspace.moveKeys, field: .moveKeys(workspace.id))
        }
    }

    private var remove: some View {
        RemoveButton { model.removeWorkspace(workspace.id) }
    }
}

/// An app of the scratchpad with its two shortcuts.
private struct ScratchpadRow: View {
    @ObservedObject var model: TilingModel
    let pad: TilingModel.ScratchpadApp

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                AppLabel(bundleID: pad.bundleID).padding(.bottom, 4)
                Spacer(minLength: 12)
                shortcuts
                remove.padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppLabel(bundleID: pad.bundleID)
                    Spacer(minLength: 12)
                    remove
                }
                shortcuts
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 10) {
            ShortcutField(model: model, title: "Show / hide", keys: pad.toggleKeys, field: .shortcut(pad.toggleAction))
            ShortcutField(model: model, title: "To tiling and back", keys: pad.tileKeys, field: .shortcut(pad.tileAction))
        }
    }

    private var remove: some View {
        RemoveButton { model.removeScratchpadApp(pad.bundleID) }
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
    static let capWidth: CGFloat = 112
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

/// A shortcut cap with a small caption above it, for rows that wrap onto two lines.
private struct ShortcutField: View {
    @ObservedObject var model: TilingModel
    let title: String
    let keys: String
    let field: TilingModel.Field

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ShortcutCap(model: model, keys: keys, field: field)
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
