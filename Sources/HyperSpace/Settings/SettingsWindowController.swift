import AppKit
import Combine
import SwiftUI

/// Which page of the settings window is shown.
final class SettingsNavigation: ObservableObject {
    enum Page: Hashable, CaseIterable {
        case keyboard, mouse, trackpad, tiling, workspaces, windowRules, shortcuts, general

        /// Pages whose features stay off, fully or in part, without the Accessibility permission
        /// (the keyboard's combinations and lock, and the trackpad's held pointer, go through
        /// the event tap). General shows its own notice.
        var needsPermission: Bool { self != .general }

        var title: String {
            switch self {
            case .keyboard: return "Keyboard"
            case .mouse: return "Mouse"
            case .trackpad: return "Trackpad"
            case .tiling: return "Tiling"
            case .workspaces: return "Workspaces"
            case .windowRules: return "Window Rules"
            case .shortcuts: return "Shortcuts"
            case .general: return "General"
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
            case .general: return "gearshape.fill"
            }
        }

        var color: Color {
            switch self {
            case .keyboard, .general: return Color(red: 0.49, green: 0.50, blue: 0.54)
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
            case .trackpad: return "Slide along the edges for the volume, the brightness or seeking; double-tap a corner to run an action."
            case .tiling: return "How windows are arranged on each display."
            case .workspaces: return "Virtual workspaces, their shortcuts and the apps that open in each."
            case .windowRules: return "Windows that float and apps kept in the scratchpad."
            case .shortcuts: return "Keys to move the focus and windows, resize and change display."
            // General opens with the app's own card, not a hero: no line.
            case .general: return ""
            }
        }
    }

    @Published var page: Page = .keyboard {
        // A key press or click meant for one page must not be captured by another.
        didSet { if page != oldValue { onSwitch?() } }
    }
    var onSwitch: (() -> Void)?
}

/// The models behind the settings pages, built together for a window (or for the snapshots).
struct SettingsModels {
    let keyboard: KeyboardModel
    let mouse: MouseModel
    let trackpad: TrackpadModel
    let tiling: TilingModel
    let general: GeneralModel

    init(remapper: KeyboardRemapper, eventTap: EventTap, actions: GeneralModel.Actions) {
        // The file is read once for every page. One with a syntax error, or one that cannot be
        // read, shows as empty, every page saying why (nothing can be saved until it is fixed);
        // the fix then loads.
        let (data, config) = ConfigWriter.parseFile(ConfigStore.url)
        keyboard = KeyboardModel(remapper: remapper, eventTap: eventTap, config: config ?? [:])
        mouse = MouseModel(eventTap: eventTap, config: config ?? [:])
        trackpad = TrackpadModel(config: config ?? [:])
        tiling = TilingModel(eventTap: eventTap, config: config ?? [:])
        general = GeneralModel(actions: actions)
        if config == nil {
            // No bytes at all: the file is there but cannot be read, which is not a syntax error.
            let message = data == nil ? SaveStatus.unreadableMessage : ConfigWriter.SyntaxError.message
            for page in files { page.saveStatus.setUnreadable(message) }
        }
    }

    /// The models that show and write a part of the file.
    private var files: [any FileBackedModel] { [keyboard, mouse, trackpad, tiling] }

    /// The file was loaded (by the app, after any change): pages whose part of it changed
    /// elsewhere show the new values, a page whose last save failed saves again, and the
    /// status follows. A file that does not parse changes nothing on the pages: the settings
    /// keep what they showed.
    func reload() {
        if let root = ConfigWriter.readIfValid() {
            for page in files { page.reload(from: root) }
        }
        // Only the config error can have changed: the login item and the permission are
        // checked when the app becomes active.
        general.refreshConfigProblem()
    }

    /// The window closes: captures end, a pending rename or slider change is saved, observers go.
    func close() {
        for page in files { page.close() }
    }

    /// A key press or click being recorded on one page must not stay armed on another, nor
    /// once the window or the app is no longer the active one (shortcuts and remaps are
    /// suspended while recording).
    func stopCaptures() {
        for page in files { page.stopCapture() }
    }
}

struct SettingsRoot: View {
    @ObservedObject var navigation: SettingsNavigation
    let keyboard: KeyboardModel
    let mouse: MouseModel
    let trackpad: TrackpadModel
    let tiling: TilingModel
    @ObservedObject var general: GeneralModel

    private typealias Page = SettingsNavigation.Page

    init(navigation: SettingsNavigation, models: SettingsModels) {
        self.navigation = navigation
        keyboard = models.keyboard
        mouse = models.mouse
        trackpad = models.trackpad
        tiling = models.tiling
        general = models.general
    }

    var body: some View {
        NavigationSplitView {
            // A sidebar always shows a page: a click that deselects the row (⌘-click) is ignored.
            List(selection: Binding<Page?>(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })) {
                sidebarSection("Input", [.keyboard, .mouse, .trackpad])
                sidebarSection("Windows", [.tiling, .workspaces, .windowRules, .shortcuts])
                sidebarSection("HyperSpace", [.general])
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarStatus(general: general)
            }
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 250)
            .modifier(NoSidebarToggle())
        } detail: {
            let page = navigation.page
            Group {
                switch page {
                case .keyboard: KeyboardView(model: keyboard)
                case .mouse: MouseView(model: mouse)
                case .trackpad: TrackpadView(model: trackpad)
                case .tiling: TilingView(model: tiling.options, status: tiling.saveStatus)
                case .workspaces:
                    WorkspacesView(store: tiling, model: tiling.workspaces, capture: tiling.capture,
                                   conflicts: tiling.conflicts, apps: tiling.apps)
                case .windowRules:
                    WindowRulesView(store: tiling, model: tiling.rules, capture: tiling.capture,
                                    conflicts: tiling.conflicts, apps: tiling.apps)
                case .shortcuts:
                    ShortcutsView(store: tiling, model: tiling.shortcuts, capture: tiling.capture, conflicts: tiling.conflicts)
                case .general: GeneralView(model: general)
                }
            }
            .navigationTitle(page.title)
            .environment(\.permissionMissing, page.needsPermission && !general.accessibilityGranted)
            .environment(\.openConfig, general.actions.openConfig)
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
                StatusPill(text: state.text, color: state.color, compact: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help("HyperSpace \(AppInfo.version)")
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
    /// The size it first opens at (then the size it was left at).
    static let defaultSize = NSSize(width: 900, height: 640)
    private static let frameName = "HyperSpaceSettings"

    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private let actions: GeneralModel.Actions
    private var window: NSWindow?
    private var models: SettingsModels?
    private var observers: [NSObjectProtocol] = []

    init(remapper: KeyboardRemapper, eventTap: EventTap, actions: GeneralModel.Actions) {
        self.remapper = remapper
        self.eventTap = eventTap
        self.actions = actions
    }

    func show() {
        if window == nil {
            let models = SettingsModels(remapper: remapper, eventTap: eventTap, actions: actions)
            let navigation = SettingsNavigation()
            navigation.onSwitch = { [weak self] in self?.models?.stopCaptures() }
            let root = SettingsRoot(navigation: navigation, models: models)
            let window = Self.makeWindow(root, size: Self.defaultSize)
            window.delegate = self
            // Where it was left; in the middle of the screen the first time.
            if !window.setFrameUsingName(Self.frameName) { window.center() }
            window.setFrameAutosaveName(Self.frameName)
            self.window = window
            self.models = models
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: ConfigStore.didLoad, object: nil, queue: .main) { [weak self] _ in
                    self?.models?.reload()
                },
                // Another app comes forward while a cap records: the recording ends, or the
                // shortcuts and remaps it suspends would stay off with nobody to end it.
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    self?.models?.stopCaptures()
                },
            ]
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

    /// The window is no longer the key one (another window or app, a panel, the window
    /// minimized): a recording in progress ends, like on a page switch.
    func windowDidResignKey(_ notification: Notification) {
        models?.stopCaptures()
    }

    /// The config error changed without a load (a write that failed): General shows it.
    func configProblemChanged() {
        models?.general.refreshConfigProblem()
    }

    func windowWillClose(_ notification: Notification) {
        models?.close()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        window = nil
        models = nil
        AppLauncher.forgetAppInfo()
        NSApp.setActivationPolicy(.accessory)
    }
}
