import AppKit
import HyperSpaceCore

/// Menu bar item. The menu is rebuilt only when it's about to open, so idle cost is zero.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private unowned let controller: AppController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    /// Updates the icon; the menu content is rebuilt in `menuNeedsUpdate`.
    func refresh() {
        let healthy = controller.accessibility.isGranted && controller.configError == nil
        let symbol = healthy ? "steeringwheel" : "exclamationmark.triangle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HyperSpace")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.accessibility.refresh()
        menu.removeAllItems()

        menu.addItem(disabled("HyperSpace \(HyperSpace.version)"))
        menu.addItem(.separator())

        if controller.accessibility.isGranted {
            menu.addItem(disabled("Accessibility: granted"))
        } else {
            menu.addItem(action("Grant Accessibility…", #selector(grantAccessibility)))
        }

        if let error = controller.configError {
            menu.addItem(disabled("Config error:"))
            for line in error.message.split(separator: "\n") { menu.addItem(disabled("  " + line)) }
        } else {
            menu.addItem(disabled("Config: OK"))
        }
        menu.addItem(action("Reload Config", #selector(reloadConfig), key: "r"))
        menu.addItem(action("Open Config", #selector(openConfig), key: "o"))
        menu.addItem(.separator())

        let login = action("Launch at Login", #selector(toggleLoginItem))
        login.state = LoginItem.isEnabled ? .on : .off
        login.isEnabled = LoginItem.isAvailable
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(action("Quit HyperSpace", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func grantAccessibility() { controller.openAccessibilitySettings() }
    @objc private func reloadConfig() { controller.reloadConfig() }
    @objc private func openConfig() { controller.openConfig() }
    @objc private func toggleLoginItem() { LoginItem.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
