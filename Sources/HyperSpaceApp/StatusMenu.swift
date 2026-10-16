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
        let healthy = controller.accessibility.isGranted && controller.configErrors.isEmpty
        if !healthy && controller.isEnabled {
            item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "HyperSpace: needs attention")
        } else if let wm = controller.wm, case let workspaces = wm.shownWorkspaces, !workspaces.isEmpty {
            // Each display's workspace, the focused one filled, with the mode's initial outside main.
            item.button?.image = MenuBarIcon.label(workspaces: workspaces, mode: wm.mode == "main" ? nil : wm.mode)
        } else {
            item.button?.image = MenuBarIcon.image
        }
        item.button?.appearsDisabled = !controller.isEnabled // dimmed while off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.accessibility.refresh()
        menu.removeAllItems()

        addWorkspaces()

        menu.addItem(disabled("HyperSpace \(HyperSpace.version)"))
        let enabled = action("Enabled", #selector(toggleEnabled), key: "e")
        enabled.state = controller.isEnabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        if controller.accessibility.isGranted {
            menu.addItem(disabled("Accessibility: granted"))
        } else {
            menu.addItem(action("Grant Accessibility…", #selector(grantAccessibility)))
        }

        if controller.configErrors.isEmpty {
            menu.addItem(disabled("Config: OK"))
        } else {
            for error in controller.configErrors {
                menu.addItem(disabled("Error in \((error.path as NSString).lastPathComponent):"))
                for line in error.message.split(separator: "\n") { menu.addItem(disabled("  " + line)) }
            }
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

    /// Size of the app icons in the workspace rows.
    private static let iconSize: CGFloat = 16

    /// Every workspace with windows, the focused one checked, with its apps' icons lined up
    /// in a column after the names. A click shows the workspace.
    private func addWorkspaces() {
        guard controller.isEnabled, case let rows = controller.wm.workspaceApps, !rows.isEmpty else { return }
        let font = NSFont.menuFont(ofSize: 0), size = Self.iconSize
        let names = rows.map { ceil(($0.name as NSString).size(withAttributes: [.font: font]).width) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: (names.max() ?? 0) + size)]
        var icons: [pid_t: NSImage] = [:]
        for row in rows {
            let title = NSMutableAttributedString(string: row.name + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
            for app in row.apps {
                guard let icon = icons[app.pid] ?? NSRunningApplication(processIdentifier: app.pid)?.icon else { continue }
                icons[app.pid] = icon
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            let item = action(row.name, #selector(showWorkspace(_:)))
            item.attributedTitle = title
            item.representedObject = row.name
            item.state = row.focused ? .on : .off
            item.toolTip = row.apps.map(\.name).joined(separator: ", ")
            menu.addItem(item)
        }
        menu.addItem(.separator())
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

    @objc private func showWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let error = controller.wm.run(words: ["workspace", name]).error { HyperSpace.logger("app").error("menu: \(error)") }
    }

    @objc private func toggleEnabled() { controller.setEnabled(!controller.isEnabled) }
    @objc private func grantAccessibility() { controller.openAccessibilitySettings() }
    @objc private func reloadConfig() { controller.reloadConfig() }
    @objc private func openConfig() { controller.openConfig() }
    @objc private func toggleLoginItem() { LoginItem.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
}
