import AppKit
import SwiftUI

/// Owns the settings window: a native preferences window with Keyboard and Mouse
/// toolbar tabs. It is built on demand and torn down on close, so it costs nothing
/// while it is not open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let remapper: KeyboardRemapper
    private let eventTap: EventTap
    private var window: NSWindow?
    private var keyboard: RemapModel?
    private var mouse: MouseModel?

    init(remapper: KeyboardRemapper, eventTap: EventTap) {
        self.remapper = remapper
        self.eventTap = eventTap
    }

    func show() {
        if window == nil {
            let keyboard = RemapModel(remapper: remapper)
            let mouse = MouseModel(eventTap: eventTap)
            let tabs = SettingsTabs()
            tabs.tabStyle = .toolbar
            tabs.addTabViewItem(Self.tab(RemapView(model: keyboard), title: "Keyboard", symbol: "keyboard"))
            tabs.addTabViewItem(Self.tab(MouseView(model: mouse), title: "Mouse", symbol: "computermouse"))
            // A key press or click meant for one tab must not be captured by the other.
            tabs.onSwitch = { [weak keyboard, weak mouse] in
                keyboard?.stopCapture()
                mouse?.stopCapture()
            }

            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
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

    private static func tab<V: View>(_ view: V, title: String, symbol: String) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        // The tab controller sizes the window from each tab's preferred content size.
        controller.sizingOptions = [.preferredContentSize]
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

private final class SettingsTabs: NSTabViewController {
    var onSwitch: (() -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSwitch?()
    }
}
