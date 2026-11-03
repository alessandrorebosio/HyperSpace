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

        /// One line under the page's title, like the panes of System Settings.
        var summary: String {
            switch self {
            case .keyboard: return "Remap keys on each keyboard, and lock the keyboard while you clean it."
            case .mouse: return "Give extra mouse buttons an action, and choose the scroll direction."
            case .tiling: return "Arrange windows side by side, in columns or as an accordion, inside each display's visible area."
            case .workspaces: return "Virtual workspaces on every display, their shortcuts, and the apps that open in each."
            case .windowRules: return "Windows that float above the tiling, and apps that live in the scratchpad."
            case .shortcuts: return "Keys to move the focus and windows, resize, change display and more."
            case .settings: return "Startup, the configuration file and permissions."
            }
        }

        /// Extra words the sidebar search matches.
        var keywords: String {
            switch self {
            case .keyboard: return "remap lock keys caps hyper"
            case .mouse: return "buttons scroll reverse drag"
            case .tiling: return "layout gap margin padding accordion columns tall wide monocle focus pointer"
            case .workspaces: return "apps rules assign spaces"
            case .windowRules: return "floating scratchpad title"
            case .shortcuts: return "keys focus move resize display float accordion"
            case .settings: return "login startup config file permission accessibility quit version"
            }
        }

        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespaces)
            return query.isEmpty || "\(title) \(keywords)".localizedCaseInsensitiveContains(query)
        }
    }

    @Published var page: Page? = .keyboard {
        // A key press or click meant for one page must not be captured by another.
        didSet { if page != oldValue { onSwitch?() } }
    }
    var onSwitch: (() -> Void)?
    /// The sidebar search.
    @Published var query = ""
}

struct SettingsRoot: View {
    @ObservedObject var navigation: SettingsNavigation
    let keyboard: RemapModel
    let mouse: MouseModel
    let tiling: TilingModel
    @ObservedObject var general: GeneralModel
    private var query: String { navigation.query }

    private typealias Page = SettingsNavigation.Page

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                sidebarSection("Input", [.keyboard, .mouse])
                sidebarSection("Windows", [.tiling, .workspaces, .windowRules, .shortcuts])
                sidebarSection(nil, [.settings])
            }
            .searchable(text: $navigation.query, placement: .sidebar, prompt: "Search")
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
        let shown = pages.filter { $0.matches(query) }
        if !shown.isEmpty {
            if let title {
                Section(title) { ForEach(shown, id: \.self) { SidebarItem(page: $0).tag($0) } }
            } else {
                Section { ForEach(shown, id: \.self) { SidebarItem(page: $0).tag($0) } }
            }
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

/// First section of every page, like the panes of System Settings: the page's icon large,
/// its name and what it is for, centered.
struct PageHeader: View {
    @Environment(\.settingsPage) private var page

    var body: some View {
        if let page {
            Section {
                VStack(spacing: 8) {
                    SidebarIcon(symbol: page.symbol, color: page.color, size: 54)
                    Text(page.title).font(.title2.weight(.bold))
                    Text(page.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
    }
}

/// A row title with a small colored icon on its left, as in the lists of System Settings.
struct IconLabel: View {
    let title: String
    var detail: String?
    let symbol: String
    let color: Color

    init(_ title: String, detail: String? = nil, symbol: String, color: Color) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 10) {
            SidebarIcon(symbol: symbol, color: color, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A sidebar row like System Settings: a white symbol on a small rounded square with a soft
/// top-to-bottom gradient, a hairline edge and a faint shadow.
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

/// A white symbol on a rounded square, as in System Settings. Drawn as vectors (sharp at any
/// size and scale) with explicit colors, so the sidebar does not tint it. Every symbol is scaled
/// to fit the same box, so wide ones (keyboard) and tall ones (mouse) look the same size and sit
/// in the middle; the square has a vertical gradient, a soft highlight on top and a hairline edge.
struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
        let glyph = size * Self.glyphShare(symbol)
        ZStack {
            shape.fill(LinearGradient(colors: [color.blended(with: .white, by: 0.28), color, color.blended(with: .black, by: 0.12)],
                                      startPoint: .top, endPoint: .bottom))
            // A soft sheen on the upper half, like the system's icons.
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
            if let ink = SymbolInk.image(symbol) {
                // Cropped to what the symbol really draws, so fitting it centers the drawing
                // itself, not the symbol's box (most symbols have uneven blank space in it).
                Image(nsImage: ink)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: glyph, height: glyph)
                    .shadow(color: .black.opacity(0.18), radius: size * 0.02, y: size * 0.02)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: size * 0.03, y: size * 0.025)
        .accessibilityHidden(true)
    }

    /// The box each symbol fits in, as a share of the icon: symbols that fill their box (a gear,
    /// ⌘) get a little less room than airy ones, so they read the same.
    private static func glyphShare(_ symbol: String) -> CGFloat {
        switch symbol {
        case "keyboard.fill", "rectangle.split.3x1.fill", "macwindow.on.rectangle": return 0.64
        case "gearshape.fill", "command": return 0.56
        default: return 0.58
        }
    }
}

/// A white SF Symbol cropped to its drawn pixels, rendered large (512 px) so it stays sharp when
/// scaled down. Cached per symbol.
enum SymbolInk {
    private static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String) -> NSImage? {
        if let image = cache[symbol] { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold).applying(.init(paletteColors: [.white]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        let width = Int(glyph.size.width.rounded(.up)), height = Int(glyph.size.height.rounded(.up))
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        glyph.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        // The box of the pixels drawn (alpha above a trace).
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = rep.cgImage?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
        let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        image.isTemplate = false
        cache[symbol] = image
        return image
    }
}

private extension Color {
    /// `self` blended toward `other`. Not called `mix`: macOS 15 adds `Color.mix(with:by:)`, which would be ambiguous.
    func blended(with other: NSColor, by amount: CGFloat) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return Color(nsColor: base.blended(withFraction: amount, of: other) ?? base)
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
