import AppKit
import SwiftUI

/// Which page of the settings window is shown.
final class SettingsNavigation: ObservableObject {
    enum Page: Hashable, CaseIterable {
        case keyboard, mouse, tiling, workspaces, windowRules, shortcuts, settings

        /// Pages whose features stay off without the Accessibility permission.
        var needsPermission: Bool { self != .keyboard && self != .settings }

        var title: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .mouse: return "Mouse"
            case .tiling: return "Tiling"
            case .workspaces: return "Workspaces"
            case .windowRules: return "Window Rules"
            case .shortcuts: return "Shortcuts"
            case .settings: return "General"
            }
        }

        var symbol: String {
            switch self {
            case .keyboard: return "keyboard.fill"
            case .mouse: return "computermouse.fill"
            case .tiling: return "rectangle.split.3x1.fill"
            case .workspaces: return "square.stack.3d.up.fill"
            case .windowRules: return "macwindow.on.rectangle"
            case .shortcuts: return "command"
            case .settings: return "gearshape.fill"
            }
        }

        var color: Color {
            switch self {
            case .keyboard, .settings: return Color(red: 0.49, green: 0.50, blue: 0.54)
            case .mouse: return Color(red: 0.10, green: 0.48, blue: 0.96)
            case .tiling: return Color(red: 0.31, green: 0.33, blue: 0.90)
            case .workspaces: return Color(red: 0.58, green: 0.30, blue: 0.88)
            case .windowRules: return Color(red: 0.97, green: 0.53, blue: 0.05)
            case .shortcuts: return Color(red: 0.93, green: 0.23, blue: 0.36)
            }
        }

        /// One line at the top of the page.
        var summary: String {
            switch self {
            case .keyboard: return "Remap keys, on every keyboard or just one, and lock the keyboard to clean it."
            case .mouse: return "Give extra mouse buttons an action and choose the scroll direction."
            case .tiling: return "How windows are arranged on each display."
            case .workspaces: return "Virtual workspaces, their shortcuts and the apps that open in each."
            case .windowRules: return "Windows that float and apps kept in the scratchpad."
            case .shortcuts: return "Keys to move the focus and windows, resize and change display."
            case .settings: return "Startup, the configuration file and permissions."
            }
        }
    }

    @Published var page: Page? = .keyboard {
        // A key press or click meant for one page must not be captured by another.
        didSet { if page != oldValue { onSwitch?() } }
    }
    var onSwitch: (() -> Void)?
}

struct SettingsRoot: View {
    @ObservedObject var navigation: SettingsNavigation
    let keyboard: RemapModel
    let mouse: MouseModel
    let tiling: TilingModel
    @ObservedObject var general: GeneralModel

    private typealias Page = SettingsNavigation.Page

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                sidebarSection("Input", [.keyboard, .mouse])
                sidebarSection("Windows", [.tiling, .workspaces, .windowRules, .shortcuts])
                sidebarSection(nil, [.settings])
            }
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
            .modifier(NoSidebarToggle())
        } detail: {
            let page = navigation.page ?? .keyboard
            Group {
                switch page {
                case .keyboard: RemapView(model: keyboard)
                case .mouse: MouseView(model: mouse)
                case .tiling: TilingView(model: tiling)
                case .workspaces: WorkspacesView(model: tiling)
                case .windowRules: WindowRulesView(model: tiling)
                case .shortcuts: TilingShortcutsView(model: tiling)
                case .settings: GeneralView(model: general)
                }
            }
            .navigationTitle(page.title)
            .environment(\.permissionMissing, page.needsPermission && !general.accessibilityGranted)
            .environment(\.settingsPage, page)
        }
        .frame(minWidth: 720, minHeight: 460)
        .modifier(GlassToolbar())
    }

    @ViewBuilder
    private func sidebarSection(_ title: String?, _ pages: [Page]) -> some View {
        if let title {
            Section(title) { ForEach(pages, id: \.self) { SidebarItem(page: $0).tag($0) } }
        } else {
            Section { ForEach(pages, id: \.self) { SidebarItem(page: $0).tag($0) } }
        }
    }
}

private struct SettingsPageKey: EnvironmentKey {
    static let defaultValue: SettingsNavigation.Page? = nil
}

extension EnvironmentValues {
    /// The page being shown, for its header.
    var settingsPage: SettingsNavigation.Page? {
        get { self[SettingsPageKey.self] }
        set { self[SettingsPageKey.self] = newValue }
    }
}

/// First row of every page: one short line saying what the page is for. The page's name is
/// the window title, so it is not repeated here.
struct PageHeader: View {
    @Environment(\.settingsPage) private var page

    var body: some View {
        if let page {
            Section {
                Text(page.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
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

/// A sidebar row like System Settings: the page's icon and its name.
private struct SidebarItem: View {
    let page: SettingsNavigation.Page

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            SidebarIcon(symbol: page.symbol, color: page.color)
        }
    }
}

/// A white symbol on a colored rounded square, as in System Settings. The symbol is a vector
/// (sharp at any scale) in an explicit color, so the sidebar does not tint it; the square has
/// a light sheen on top and a hairline edge.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
        ZStack {
            shape.fill(color)
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Liquid Glass: no opaque toolbar band; the content scrolls under the title bar like in
/// the system apps.
private struct GlassToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// The sidebar always stays: without its toggle the window needs no toolbar at all.
/// Only takes effect on the sidebar column itself.
private struct NoSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// Owns the settings window: sidebar with the input, window and app pages. It is built
/// on demand and torn down on close, so it costs nothing while it is not open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private let actions: GeneralModel.Actions
    private var window: NSWindow?
    private var keyboard: RemapModel?
    private var mouse: MouseModel?
    private var tiling: TilingModel?

    init(remapper: KeyboardRemapper, eventTap: EventTap, actions: GeneralModel.Actions) {
        self.remapper = remapper
        self.eventTap = eventTap
        self.actions = actions
    }

    func show() {
        if window == nil {
            let keyboard = RemapModel(remapper: remapper, eventTap: eventTap)
            let mouse = MouseModel(eventTap: eventTap)
            let tiling = TilingModel(eventTap: eventTap)
            let navigation = SettingsNavigation()
            navigation.onSwitch = { [weak keyboard, weak mouse, weak tiling] in
                keyboard?.stopCapture()
                mouse?.stopCapture()
                tiling?.stopCapture()
            }
            let root = SettingsRoot(navigation: navigation, keyboard: keyboard, mouse: mouse, tiling: tiling,
                                    general: GeneralModel(actions: actions))
            let controller = NSHostingController(rootView: root)
            // Only a minimum size: the preferred size would pin the window and block resizing.
            controller.sizingOptions = [.minSize]
            // SwiftUI owns the toolbar and the title (the page's), so the sidebar is the system
            // Liquid Glass one and lines up with the window controls. This only takes when the
            // controller is set on an existing window, not with NSWindow(contentViewController:).
            if #available(macOS 14, *) { controller.sceneBridgingOptions = [.all] }

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.contentViewController = controller
            if #unavailable(macOS 14) { window.title = "HyperSpace" }
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 900, height: 640))
            window.setFrameAutosaveName("HyperSpaceSettings")
            window.center()
            self.window = window
            self.keyboard = keyboard
            self.mouse = mouse
            self.tiling = tiling
        }
        // In the Dock and ⌘Tab while the window is open, like a regular app.
        NSApp.setActivationPolicy(.regular)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        keyboard?.stopCapture()
        mouse?.stopCapture()
        tiling?.stopCapture()
        remapper.onKeyboardsChanged = nil
        window = nil
        keyboard = nil
        mouse = nil
        tiling = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
