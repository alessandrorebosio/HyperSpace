import AppKit
import SwiftUI

/// Owns the remap editor window. It is built on demand and torn down on close,
/// so the editor costs nothing while it is not open.
final class RemapWindowController: NSObject, NSWindowDelegate {
    private let remapper: KeyboardRemapper
    private var window: NSWindow?
    private var model: RemapModel?

    init(remapper: KeyboardRemapper) {
        self.remapper = remapper
    }

    func show() {
        if window == nil {
            let model = RemapModel(remapper: remapper)
            let window = NSWindow(contentViewController: NSHostingController(rootView: RemapView(model: model)))
            window.title = "Keyboard Remapping"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 700, height: 500))
            window.center()
            self.window = window
            self.model = model
        }
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stopCapture()
        remapper.onKeyboardsChanged = nil
        window = nil
        model = nil
    }
}
