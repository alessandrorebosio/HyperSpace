import AppKit
import SwiftUI

/// Which page of the settings window is shown.
final class SettingsNavigation: ObservableObject {
    enum Page: Hashable {
        case keyboard, mouse, settings
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
    let general: GeneralModel

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.page) {
                Label("Keyboard", systemImage: "keyboard").tag(SettingsNavigation.Page.keyboard)
                Label("Mouse", systemImage: "computermouse").tag(SettingsNavigation.Page.mouse)
                Section {
                    Label("Settings", systemImage: "gearshape").tag(SettingsNavigation.Page.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            switch navigation.page ?? .keyboard {
            case .keyboard: RemapView(model: keyboard).navigationTitle("Keyboard")
            case .mouse: MouseView(model: mouse).navigationTitle("Mouse")
            case .settings: GeneralView(model: general).navigationTitle("Settings")
            }
        }
        .frame(minWidth: 820, minHeight: 500)
    }
}

/// Owns the settings window: sidebar with Keyboard, Mouse and Settings. It is built
/// on demand and torn down on close, so it costs nothing while it is not open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private let actions: GeneralModel.Actions
    private var window: NSWindow?
    private var keyboard: RemapModel?
    private var mouse: MouseModel?

    init(remapper: KeyboardRemapper, eventTap: EventTap, actions: GeneralModel.Actions) {
        self.remapper = remapper
        self.eventTap = eventTap
        self.actions = actions
    }

    func show() {
        if window == nil {
            let keyboard = RemapModel(remapper: remapper)
            let mouse = MouseModel(eventTap: eventTap)
            let navigation = SettingsNavigation()
            navigation.onSwitch = { [weak keyboard, weak mouse] in
                keyboard?.stopCapture()
                mouse?.stopCapture()
            }
            let root = SettingsRoot(navigation: navigation, keyboard: keyboard, mouse: mouse,
                                    general: GeneralModel(actions: actions))
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = [.preferredContentSize]

            let window = NSWindow(contentViewController: controller)
            window.title = "HyperSpace"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            self.keyboard = keyboard
            self.mouse = mouse
        }
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
        remapper.onKeyboardsChanged = nil
        window = nil
        keyboard = nil
        mouse = nil
    }
}
