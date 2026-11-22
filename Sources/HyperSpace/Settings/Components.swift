import AppKit
import SwiftUI

// Containers store the views their builder made (`@ViewBuilder let content: Content`), not the
// closure: a stored closure can never compare equal, so SwiftUI could not tell that the
// content is unchanged and would rebuild it on every redraw of the parent.
//
// The building blocks every settings page is made of. A page is a grouped Form that starts
// with a PageHero; lists put their add button in the section header (SectionHeader); keys and
// shortcuts are KeyCaps; anything that needs attention is a NoticeRow at the top.

// MARK: - Icons

/// A white symbol on a colored rounded square, as in System Settings: the sidebar (20 pt),
/// notices (28 pt) and page heroes (44 pt). The symbol is a vector in an explicit color, so
/// it stays sharp at every size and the sidebar's selection does not tint it. Every symbol
/// gets the same square, so wide ones (keyboard) and narrow ones (command) look the same size.
struct PageIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
        ZStack {
            shape.fill(color.gradient)
            shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.15), radius: 0.5, x: 0, y: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An installed app: its icon and name; the bundle id in the tooltip.
struct AppLabel: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppLauncher.icon(bundleID) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").font(.title3).foregroundStyle(.tertiary).frame(width: 22, height: 22)
            }
            Text(AppLauncher.name(bundleID)).lineLimit(1).truncationMode(.tail)
        }
        .help(bundleID)
        // One element for VoiceOver: the app's name (the icon alone says nothing).
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Page structure

/// First section of every page: the page's icon, name and what it is for, with an optional
/// control on the right (the Tiling page puts its on/off switch there, like Wi-Fi in System
/// Settings).
struct PageHero<Accessory: View>: View {
    let page: SettingsNavigation.Page
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Section {
            HStack(spacing: 14) {
                PageIcon(symbol: page.symbol, color: page.color, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(page.title).font(.title3.weight(.semibold))
                    Text(page.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.rowGap)
                accessory
            }
            .padding(.vertical, 6)
        }
    }
}

extension PageHero where Accessory == EmptyView {
    init(page: SettingsNavigation.Page) {
        self.init(page: page) { EmptyView() }
    }
}

/// A section title with the section's action on the right, usually its add button.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer(minLength: Metrics.rowGap)
            trailing
        }
    }
}

/// A row title with an optional line of explanation under it, as in System Settings.
struct RowLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A setting with a line of explanation under its title and its control on the right,
/// vertically centered on both lines (a Form row would align the control with the first).
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.rowGap) {
            RowLabel(title, detail: detail)
            Spacer(minLength: Metrics.rowGap)
            control
        }
    }
}

/// A switch whose title is hidden (the row around it shows one), reading a model's value
/// and changing it through the model's setter.
struct SettingSwitch: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// A setting that is a switch: title and explanation on the left, the switch on the right.
struct SwitchRow: View {
    let title: String
    var detail: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        SettingRow(title: title, detail: detail) {
            SettingSwitch(title: title, isOn: isOn, set: set)
        }
    }
}

/// What an empty list shows, centered, instead of nothing.
struct EmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// A caption under a section, styled the same on every page. Errors are not captions: an
/// `ErrorLabel` in the section, or the notice at the top of the page for a save error.
struct SectionFooter: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    // A grouped Form puts footers on the trailing side (for buttons): text reads from the leading edge.
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.caption)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            // In line with the section's title and rows, which the Form insets by as much.
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An error about one section (Launch at login, the config file), as a row of it: the one way
/// an error that is not a save error is shown.
struct ErrorLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: Wording.warningSymbol)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A colored dot and a word: on a tinted capsule, or plain and small (the sidebar).
struct StatusPill: View {
    let text: String
    let color: Color
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).font(.callout.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
        }
    }
}

extension GeneralModel.Health {
    /// The color of the status dot.
    var color: Color {
        switch self {
        case .running: return .green
        case .permissionMissing: return .orange
        case .configProblem: return .red
        }
    }
}

// MARK: - Rule rows

/// A rule row of the Keyboard and Mouse pages: on one line when it fits, else the first part
/// with the trailing controls on one line and the second part under them.
struct RuleRowLayout<First: View, Second: View, Trailing: View>: View {
    /// On one line, the second part sits before the trailing controls (a picker) rather than
    /// next to the first (an arrow and a target).
    var secondAtEnd = false
    var spacing = Metrics.ruleSpacing
    /// Put before the second part when it has a line of its own ("On" before a keyboard).
    var secondLabel: String?
    let first: First
    let second: Second
    let trailing: Trailing

    init(secondAtEnd: Bool = false, spacing: CGFloat = Metrics.ruleSpacing, secondLabel: String? = nil,
         @ViewBuilder first: () -> First, @ViewBuilder second: () -> Second, @ViewBuilder trailing: () -> Trailing) {
        self.secondAtEnd = secondAtEnd
        self.spacing = spacing
        self.secondLabel = secondLabel
        self.first = first()
        self.second = second()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                first
                if secondAtEnd {
                    Spacer(minLength: Metrics.rowGap)
                    second
                } else {
                    second
                    Spacer(minLength: Metrics.rowGap)
                }
                trailing
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: spacing) {
                    first
                    Spacer(minLength: Metrics.rowGap)
                    trailing
                }
                HStack(spacing: 8) {
                    if let secondLabel { Text(secondLabel).foregroundStyle(.secondary) }
                    second
                }
            }
        }
    }
}

/// A rule about an app: its icon and name (or *Any app*), what the rule does on the right,
/// and the remove button. The rows of App Rules and Floating.
struct AppRuleRow<Detail: View>: View {
    /// nil: the rule is for any app.
    let app: String?
    let remove: () -> Void
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(spacing: 10) {
            if let app {
                AppLabel(bundleID: app)
            } else {
                Label(Wording.anyApp, systemImage: "square.grid.2x2").foregroundStyle(.secondary)
            }
            Spacer(minLength: Metrics.rowGap)
            detail
            RemoveButton(what: "the rule of \(app.map(AppLauncher.name) ?? Wording.anyApp.lowercased())", action: remove)
        }
    }
}

// MARK: - Notices

/// A notice at the top of a page: what is wrong and the one button that fixes it.
struct NoticeRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Metrics.rowGap) {
            PageIcon(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.rowGap)
            Button(button, action: action)
        }
        .padding(.vertical, 2)
    }
}

private struct PermissionMissingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on pages whose features need the Accessibility permission, while it is missing.
    var permissionMissing: Bool {
        get { self[PermissionMissingKey.self] }
        set { self[PermissionMissingKey.self] = newValue }
    }
}

/// Shown under the hero of a page that needs the Accessibility permission, while it is missing.
struct PermissionNotice: View {
    @Environment(\.permissionMissing) private var missing
    var detail = "These settings do nothing until HyperSpace is allowed in \(Wording.accessibilityPane)."

    var body: some View {
        if missing {
            Section {
                NoticeRow(symbol: "lock.shield.fill", color: .orange, title: Permissions.missingTitle,
                          detail: detail, button: Wording.openSystemSettings) { Permissions.openSettings() }
            }
        }
    }
}

private struct OpenConfigKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Opens the config file in the editor (writing the default one first if it is missing):
    /// the one action behind every *Edit Config…* button.
    var openConfig: () -> Void {
        get { self[OpenConfigKey.self] }
        set { self[OpenConfigKey.self] = newValue }
    }
}

/// Shown under the hero while the page cannot save: its last change was not written (a syntax
/// error in the file, which the writer refuses to touch), or the file could not be read when
/// the window opened. It observes the model's save status alone, so a problem coming or going
/// redraws this notice, not the page.
struct SaveErrorNotice: View {
    @ObservedObject var status: SaveStatus
    @Environment(\.openConfig) private var openConfig

    var body: some View {
        if let problem = status.problem {
            Section {
                NoticeRow(symbol: Wording.warningSymbol, color: .red, title: problem.title,
                          detail: problem.message, button: Wording.editConfig, action: openConfig)
            }
        }
    }
}

/// Shown on the window pages while tiling is off: the settings are kept but do nothing.
struct TilingOffNotice: View {
    @ObservedObject var model: TilingOptionsModel

    var body: some View {
        if !model.enabled {
            Section {
                NoticeRow(symbol: "pause.fill", color: .gray, title: "Tiling is off",
                          detail: "\(Wording.tilingOff). These settings are kept and apply as soon as it is on.",
                          button: "Turn On") { model.setEnabled(true) }
            }
        }
    }
}

// MARK: - Controls

/// A key drawn as a key cap. Clicking it starts recording; while it records it has an accent
/// ring and a red dot, like a recording shortcut field.
struct KeyCap: View {
    /// What the cap holds, for VoiceOver ("Key to remap", "Show workspace web"): the text alone
    /// ("⌘1", "None") says nothing out of its row.
    let label: String
    let text: String
    var symbol: String?
    /// Fixed width, padding included: keeps caps aligned from row to row.
    var width: CGFloat?
    /// Least width when the cap has no fixed one; it grows with its text, never truncating it.
    var minWidth: CGFloat = 36
    var placeholder = false
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if active {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                } else if let symbol {
                    Image(systemName: symbol).imageScale(.small).foregroundStyle(.secondary)
                }
                Text(text).lineLimit(1).minimumScaleFactor(width == nil ? 1 : 0.75)
            }
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(active ? Color.accentColor : (placeholder ? Color.secondary : Color.primary))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(width: width)
            .frame(minWidth: minWidth)
            .background(KeyCapBackground(active: active))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "Recording: press the keys" : "Click to record")
        .accessibilityLabel("\(label): \(text)")
        .accessibilityHint(active ? "Recording" : "Records what you press next")
    }
}

/// A key: a light face with a darker lower edge, as on the Magic Keyboard.
private struct KeyCapBackground: View {
    let active: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let dark = scheme == .dark
        shape
            .fill(dark ? Color.white.opacity(0.11) : Color.white)
            .overlay(shape.fill(LinearGradient(colors: [Color.clear, Color.black.opacity(dark ? 0.12 : 0.04)],
                                               startPoint: .top, endPoint: .bottom)))
            .shadow(color: Color.black.opacity(dark ? 0.5 : 0.2), radius: 0, x: 0, y: 1)
            .overlay(shape.strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.13),
                                        lineWidth: active ? 1.5 : 0.5))
            .overlay(shape.stroke(Color.accentColor.opacity(active ? 0.25 : 0), lineWidth: 4))
    }
}

/// The arrow between what a rule takes and what it gives (a key and its remap, a button and its action).
struct RuleArrow: View {
    var body: some View {
        Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

/// The end of a rule row: its warning, if any, and its remove button.
struct RuleTrailing: View {
    let warning: String?
    /// What the remove button removes, for VoiceOver.
    let what: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Metrics.ruleSpacing) {
            WarningBadge(text: warning)
            RemoveButton(what: what, action: remove)
        }
    }
}

/// A small bordered button with a plus, for the header of a list.
struct AddButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AddLabel(title: title)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// "+ Add App", drawn like AddButton: a menu of the candidate apps, then a last entry
/// (*Other App…*) that asks for any other app.
struct AddAppMenu: View {
    let candidates: [(name: String, bundleID: String)]
    let add: (String) -> Void
    let choose: () -> Void

    var body: some View {
        Menu {
            ForEach(candidates, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }
            }
            Divider()
            Button(Wording.otherApp, action: choose)
        } label: {
            AddLabel(title: "Add App")
        }
        .modifier(BorderedMenu())
        .controlSize(.small)
    }
}

/// "+ Title", drawn the same in a button and in a menu (a menu's Label spaces them differently).
private struct AddLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus").font(.caption.weight(.semibold))
            Text(title)
        }
    }
}

/// A named choice of a `GroupedChoiceMenu`, under its group's title.
struct ChoiceGroup {
    let title: String
    let items: [(label: String, value: String)]
}

/// A menu with a long, fixed list in submenus (every key, the ready-made actions), an optional
/// first item before a divider and an optional last one after another. Without a `title` it is
/// the small ▾ next to a key cap, for picking instead of pressing; with one it is a menu button
/// showing the current choice (a trackpad corner's action). The list never changes, so the menu
/// is only built again for another owner or title (`==`): a key press while recording redraws
/// every row, not this.
struct GroupedChoiceMenu: View, Equatable {
    /// What the menu belongs to (a rule, a corner).
    let id: AnyHashable
    /// The current choice, shown on the button; nil for the ▾.
    var title: String?
    let help: String
    let groups: [ChoiceGroup]
    var first: (label: String, value: String)?
    var last: (label: String, value: String)?
    /// Called with the chosen value; the same for a given owner.
    let choose: (String) -> Void

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.title == b.title }

    var body: some View {
        Menu {
            if let first {
                Button(first.label) { choose(first.value) }
                Divider()
            }
            ForEach(groups, id: \.title) { group in
                Menu(group.title) {
                    ForEach(group.items, id: \.value) { item in
                        Button(item.label) { choose(item.value) }
                    }
                }
            }
            if let last {
                Divider()
                Button(last.label) { choose(last.value) }
            }
        } label: {
            if let title {
                Text(title)
            } else {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
        }
        .modifier(BorderedMenu(indicator: title == nil ? .hidden : .visible))
        .controlSize(title == nil ? .small : .regular)
        .help(help)
        .accessibilityLabel(title.map { "\(help): \($0)" } ?? help)
    }
}

/// A menu that looks like a bordered button. On macOS 14+ it uses the SwiftUI button style,
/// which draws the label's symbols as vectors in their own colors; the older menu styles turn
/// the label into a template bitmap, gray and blurry.
struct BorderedMenu: ViewModifier {
    /// The ▾ the system adds: hidden when the label is itself a symbol.
    var indicator: Visibility = .hidden

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(indicator)
                .fixedSize()
        } else {
            content
                .menuStyle(.borderedButton)
                .menuIndicator(indicator)
                .fixedSize()
        }
    }
}

/// Removes a row.
///
/// No `@State` here, or anywhere in the settings views: with only the Command Line Tools, a
/// SwiftPM build cannot load the SwiftUI macro plugin that `@State` expands with on recent SDKs
/// ("external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"). View
/// state lives in the models (ObservableObject), which need no macro.
struct RemoveButton: View {
    static let width: CGFloat = 20

    /// What the button removes, for VoiceOver ("the workspace web"): every row has one.
    let what: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: Self.width, height: Self.width)
        }
        .buttonStyle(.borderless)
        .help("Remove")
        .accessibilityLabel("Remove \(what)")
    }
}

/// An orange triangle with the explanation in its tooltip; nothing when there is no warning.
struct WarningBadge: View {
    let text: String?

    var body: some View {
        if let text {
            Image(systemName: Wording.warningSymbol)
                .foregroundStyle(.orange)
                .help(text)
                .accessibilityLabel(text)
        }
    }
}

/// A setting in points: title, a slider, and the value, like the sliders of System Settings.
struct SliderRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// A new value: shown at once, saved by the model once the slider is released, or shortly
    /// after a change made with the keyboard or VoiceOver (which never "release" it).
    let onChange: (Int) -> Void
    /// The slider is grabbed (true) or released (false).
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: Metrics.rowGap) {
            Text(title).layoutPriority(1)
            Spacer(minLength: Metrics.rowGap)
            // Continuous (no tick marks), rounded to `step`. Not saved while dragged: every save
            // reloads the config and retiles the windows.
            Slider(value: Binding(get: { Double(value) },
                                  set: { onChange(Int(($0 / Double(step)).rounded()) * step) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), onEditingChanged: onEditingChanged)
            .accessibilityLabel(title)
            .accessibilityValue("\(value) points")
            .frame(minWidth: 120, maxWidth: 200)
            Text("\(value) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
