import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var keyboard: RemapModel
    @ObservedObject var mouse: MouseModel

    var body: some View {
        TabView {
            RemapView(model: keyboard)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            MouseView(model: mouse)
                .tabItem { Label("Mouse", systemImage: "computermouse") }
        }
        .padding(.top, 8)
    }
}

/// Owns the settings window. It is built on demand and torn down on close,
/// so it costs nothing while it is not open.
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(keyboard: keyboard, mouse: mouse)))
            window.title = "HyperSpace Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 720, height: 520))
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
