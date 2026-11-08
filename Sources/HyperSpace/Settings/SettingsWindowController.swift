import AppKit
import SwiftUI

/// Which page of the settings window is shown.
final class SettingsNavigation: ObservableObject {
    enum Page: Hashable, CaseIterable {
        case keyboard, mouse, trackpad, tiling, workspaces, windowRules, shortcuts, settings

        /// Pages whose features stay off without the Accessibility permission.
        var needsPermission: Bool { self != .keyboard && self != .trackpad && self != .settings }

        var title: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .mouse: return "Mouse"
            case .trackpad: return "Trackpad"
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
            case .trackpad: return "rectangle.and.hand.point.up.left.fill"
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
            case .trackpad: return Color(red: 0.05, green: 0.66, blue: 0.72)
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
            case .trackpad: return "Use the left and right edges as sliders for the volume and the brightness."
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
    let trackpad: TrackpadModel
    let tiling: TilingModel
    @ObservedObject var general: GeneralModel

    private typealias Page = SettingsNavigation.Page

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                sidebarSection("Input", [.keyboard, .mouse, .trackpad])
                sidebarSection("Windows", [.tiling, .workspaces, .windowRules, .shortcuts])
                sidebarSection("HyperSpace", [.settings])
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarStatus(general: general)
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
                case .trackpad: TrackpadView(model: trackpad)
                case .tiling: TilingView(model: tiling)
                case .workspaces: WorkspacesView(model: tiling)
                case .windowRules: WindowRulesView(model: tiling)
                case .shortcuts: ShortcutsView(model: tiling)
                case .settings: GeneralView(model: general)
                }
            }
            .navigationTitle(page.title)
            .environment(\.permissionMissing, page.needsPermission && !general.accessibilityGranted)
        }
        .frame(minWidth: SettingsWindowController.minimumSize.width, minHeight: SettingsWindowController.minimumSize.height)
        .modifier(GlassToolbar())
    }

    private func sidebarSection(_ title: String, _ pages: [Page]) -> some View {
        Section(title) {
            ForEach(pages, id: \.self) { page in
                Label {
                    Text(page.title)
                } icon: {
                    PageIcon(symbol: page.symbol, color: page.color)
                }
                .tag(page)
            }
        }
    }
}

/// Bottom of the sidebar: the app and whether it is working, always in sight. Only shown:
/// a click does nothing.
private struct SidebarStatus: View {
    @ObservedObject var general: GeneralModel

    var body: some View {
        let state = general.health
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("HyperSpace").font(.callout.weight(.semibold))
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help("HyperSpace \(general.version)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HyperSpace: \(state.text)")
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
    /// The smallest the window gets; every page is laid out to fit it.
    static let minimumSize = NSSize(width: 720, height: 460)

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
            navigation.onSwitch = { [weak self] in self?.stopAllCaptures() }
            let root = SettingsRoot(navigation: navigation, keyboard: keyboard, mouse: mouse, trackpad: TrackpadModel(), tiling: tiling,
                                    general: GeneralModel(actions: actions))
            let window = Self.makeWindow(root, size: NSSize(width: 900, height: 640))
            window.delegate = self
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

    /// The settings window around `root`, not shown yet: the app's, and the one the snapshots draw.
    static func makeWindow(_ root: SettingsRoot, size: NSSize) -> NSWindow {
        let controller = NSHostingController(rootView: root)
        // Only a minimum size: the preferred size would pin the window and block resizing.
        controller.sizingOptions = [.minSize]
        // SwiftUI owns the toolbar and the title (the page's), so the sidebar is the system
        // Liquid Glass one and lines up with the window controls. This only takes when the
        // controller is set on an existing window, not with NSWindow(contentViewController:).
        if #available(macOS 14, *) { controller.sceneBridgingOptions = [.all] }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        if #unavailable(macOS 14) { window.title = "HyperSpace" }
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumSize
        window.setContentSize(size)
        return window
    }

    /// A key press or click being recorded on one page must not stay armed on another.
    private func stopAllCaptures() {
        keyboard?.stopCapture()
        mouse?.stopCapture()
        tiling?.stopCapture()
    }

    func windowWillClose(_ notification: Notification) {
        stopAllCaptures()
        remapper.onKeyboardsChanged = nil
        window = nil
        keyboard = nil
        mouse = nil
        tiling = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
