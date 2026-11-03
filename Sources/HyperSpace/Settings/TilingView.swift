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
                    IconLabel("Tile windows", detail: "Arrange the windows of each workspace side by side. Off: windows stay where you put them.",
                              symbol: "rectangle.split.3x1.fill", color: .blue)
                }
            }

            Section {
                LayoutChooser(selection: model.layout, gap: model.gap, padding: model.padding,
                              peek: model.accordionPadding) { model.setLayout($0) }
                SliderRow(title: "Gap between windows", symbol: "arrow.left.and.right", color: .teal,
                          value: model.gap, range: 0...64, step: 2) { model.setGap($0, commit: $1) }
                SliderRow(title: "Margin around the screen", symbol: "rectangle.inset.filled", color: .cyan,
                          value: model.padding, range: 0...64, step: 2) { model.setPadding($0, commit: $1) }
            } header: {
                Text("Layout")
            } footer: {
                SettingsFooter(hint: "A layout shortcut (layout …) switches the focused display on the fly. Windows always stay inside the visible area, clear of the menu bar and the Dock.",
                               error: model.saveError)
            }
            .disabled(!model.enabled)

            Section {
                Toggle(isOn: Binding(get: { model.mouseFollowsFocus }, set: { model.setMouseFollowsFocus($0) })) {
                    IconLabel("Pointer follows focus", detail: "When the focus moves to another display, the pointer goes there too.",
                              symbol: "cursorarrow.motionlines", color: .green)
                }
            } header: {
                Text("Focus")
            }
            .disabled(!model.enabled)

            Section {
                SliderRow(title: "Visible edges", symbol: "square.stack.fill", color: .indigo,
                          value: model.accordionPadding, range: 0...120, step: 5) { model.setAccordionPadding($0, commit: $1) }
                AccordionPreview(peek: model.accordionPadding)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } header: {
                Text("Accordion")
            } footer: {
                SectionFooter("How much of the windows behind the front one shows on each side, in the Accordion layout and when you stack a workspace with the accordion shortcut (Shortcuts → Stack windows as an accordion).")
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
            PageHeader()
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

/// A setting in points: icon and title, a slider, and the value, like the sliders of System Settings.
private struct SliderRow: View {
    let title: String
    let symbol: String
    let color: Color
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// The new value, and whether it is final (the slider was released) or a drag in progress.
    let onChange: (Int, Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            IconLabel(title, symbol: symbol, color: color)
                .layoutPriority(1)
            Spacer(minLength: 12)
            // Continuous (no tick marks), rounded to `step`. Saved only on release: every save
            // reloads the config and retiles the windows.
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int(($0 / Double(step)).rounded()) * step, false) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing { onChange(value, true) }
            }
                .frame(minWidth: 140, maxWidth: 220)
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
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)).frame(maxWidth: 360))
        .accessibilityLabel("Accordion preview with \(peek) point edges")
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
    let peek: Int
    let onSelect: (LayoutKind) -> Void

    // Like the Appearance picker of System Settings: no glass of its own inside the form (the
    // grouped form already sits on the system's Liquid Glass; glass is for floating controls).
    var body: some View {
        HStack(spacing: 10) {
            ForEach(LayoutKind.allCases, id: \.self) { kind in
                LayoutOption(kind: kind, selected: kind == selection, gap: gap, padding: padding, peek: peek) { onSelect(kind) }
                    .help(Self.help(kind))
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
        case .accordion: return "Windows stacked on top of each other, the ones behind peeking out at the sides"
        }
    }
}

/// One layout: its picture and name on a softly filled tile, ringed with the accent color when chosen.
private struct LayoutOption: View {
    let kind: LayoutKind
    let selected: Bool
    let gap: Int
    let padding: Int
    let peek: Int
    let action: () -> Void

    private static let corner: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                LayoutThumbnail(kind: kind, gap: gap, padding: padding, peek: peek, selected: selected)
                    .frame(width: 84, height: 54)
                Text(kind.rawValue.capitalized)
                    .font(.callout.weight(selected ? .semibold : .medium))
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

    var body: some View {
        let scale: CGFloat = 0.15
        let inset = padding == 0 ? 0 : max(1.5, CGFloat(padding) * scale)
        let spacing = gap == 0 ? 0 : max(2.5, CGFloat(gap) * scale)
        let screenCorner: CGFloat = 9
        Canvas { context, size in
            let margin = 4 + inset
            let area = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
            let count = kind == .monocle ? 1 : 3
            let frames = Layout.frames(kind, weights: Array(repeating: 1, count: count), in: area, gap: spacing, ratio: 0.55,
                                       focused: 1, peek: max(12, CGFloat(peek) * 0.35))
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
