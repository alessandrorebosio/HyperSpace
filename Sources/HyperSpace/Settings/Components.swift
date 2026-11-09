import AppKit
import SwiftUI

// Containers store the views their builder made (`@ViewBuilder let content: Content`), not the
// closure: a stored closure can never compare equal, so SwiftUI could not tell that the
// content is unchanged and would rebuild it on every redraw of the parent.
//
// The building blocks every settings page is made of. A page is a grouped Form that starts
// with a PageHero; lists put their add button in the section header (SectionHeader); keys and
// shortcuts are KeyCaps; anything that needs attention is a NoticeRow at the top.

/// An NSEvent local monitor for key or button capture. The handler returns true when
/// it consumed the event; the monitor is removed on `stop` or when released.
final class LocalEventMonitor {
    private var token: Any?

    func start(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Bool) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: mask) { handler($0) ? nil : $0 }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { stop() }
}

extension Array where Element: Identifiable {
    /// Changes the element with `id`; false when there is none.
    @discardableResult
    mutating func update(id: Element.ID, _ change: (inout Element) -> Void) -> Bool {
        guard let index = firstIndex(where: { $0.id == id }) else { return false }
        change(&self[index])
        return true
    }
}

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
                Spacer(minLength: 12)
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
            Spacer(minLength: 12)
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
        HStack(alignment: .center, spacing: 12) {
            RowLabel(title, detail: detail)
            Spacer(minLength: 12)
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

/// A caption under a section, styled the same on every page; the last save error, when
/// there is one, takes its place.
struct SectionFooter: View {
    let text: String
    let error: String?

    init(_ text: String, error: String? = nil) {
        self.text = text
        self.error = error
    }

    // A grouped Form puts footers on the trailing side (for buttons): text reads from the leading edge.
    var body: some View {
        Group {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(text).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        // In line with the section's title and rows, which the Form insets by as much.
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Recording a shortcut

/// A settings model that records the next key or click for one field at a time.
protocol CaptureModel: AnyObject {
    associatedtype Field: Equatable
    var capturing: Field? { get }
    func startCapture(_ field: Field)
    func stopCapture()
}

extension CaptureModel {
    /// A click on a key cap: stops recording that field when it is the one recording, else starts.
    func toggleCapture(_ field: Field) {
        capturing == field ? stopCapture() : startCapture(field)
    }
}

extension KeyboardModel: CaptureModel {}
extension MouseModel: CaptureModel {}
extension TilingModel: CaptureModel {}

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
        HStack(spacing: 12) {
            PageIcon(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
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
    var detail = "These settings do nothing until HyperSpace is allowed in Privacy & Security → Accessibility."

    var body: some View {
        if missing {
            Section {
                NoticeRow(symbol: "lock.shield.fill", color: .orange, title: "Accessibility permission needed",
                          detail: detail, button: "Open System Settings…") { Permissions.openSettings() }
            }
        }
    }
}

// MARK: - Controls

/// A key drawn as a key cap. Clicking it starts recording; while it records it has an accent
/// ring and a red dot, like a recording shortcut field.
struct KeyCap: View {
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
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            WarningBadge(text: warning)
            RemoveButton(action: remove)
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

/// The same as AddButton, for lists whose new item is picked from a menu (an app).
struct AddMenu<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            AddLabel(title: title)
        }
        .modifier(BorderedMenu())
        .controlSize(.small)
    }
}

/// "+ Add App" menu: the candidate apps, then a last entry that asks for any other app.
struct AddAppMenu: View {
    let candidates: [(name: String, bundleID: String)]
    let chooseTitle: String
    let add: (String) -> Void
    let choose: () -> Void

    var body: some View {
        AddMenu(title: "Add App") {
            ForEach(candidates, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }
            }
            Divider()
            Button(chooseTitle, action: choose)
        }
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

/// A dropdown next to a key cap, for picking from a list instead of pressing the keys.
struct ChoiceMenu<Content: View>: View {
    let help: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
        }
        .modifier(BorderedMenu())
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A menu that looks like a bordered button. On macOS 14+ it uses the SwiftUI button style,
/// which draws the label's symbols as vectors in their own colors; the older menu styles turn
/// the label into a template bitmap, gray and blurry.
struct BorderedMenu: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
        } else {
            content
                .menuStyle(.borderedButton)
                .menuIndicator(.hidden)
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
        .accessibilityLabel("Remove")
    }
}

/// An orange triangle with the explanation in its tooltip; nothing when there is no warning.
struct WarningBadge: View {
    let text: String?

    var body: some View {
        if let text {
            Image(systemName: "exclamationmark.triangle.fill")
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
    /// The value while the slider is dragged; not saved yet.
    let onChange: (Int) -> Void
    /// The slider was released: save the value.
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).layoutPriority(1)
            Spacer(minLength: 12)
            // Continuous (no tick marks), rounded to `step`. Saved only on release: every save
            // reloads the config and retiles the windows.
            Slider(value: Binding(get: { Double(value) },
                                  set: { onChange(Int(($0 / Double(step)).rounded()) * step) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) { editing in
                if !editing { onCommit() }
            }
            .labelsHidden()
            .frame(minWidth: 120, maxWidth: 200)
            Text("\(value) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
