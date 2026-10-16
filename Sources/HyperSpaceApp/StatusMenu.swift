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
        addDisplays()

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
        menu.addItem(action("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(action("Quit HyperSpace", #selector(quit), key: "q"))
    }

    /// Size of the app icons in the workspace rows.
    private static let iconSize: CGFloat = 16
    /// Window titles longer than this are cut in the submenus.
    private static let titleLength = 60

    /// Every workspace with windows, the focused one checked, with its apps' icons lined up
    /// in a column after the names. Each opens a submenu: show the workspace, or one of its
    /// windows.
    private func addWorkspaces() {
        guard controller.isEnabled, case let rows = controller.wm.workspaceWindows, !rows.isEmpty else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let names = rows.map { ceil(($0.name as NSString).size(withAttributes: [.font: font]).width) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: (names.max() ?? 0) + Self.iconSize)]
        var icons: [pid_t: NSImage] = [:]
        func icon(_ pid: pid_t) -> NSImage? {
            if let icon = icons[pid] { return icon }
            guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
            icon.size = NSSize(width: Self.iconSize, height: Self.iconSize)
            icons[pid] = icon
            return icon
        }
        for row in rows {
            let title = NSMutableAttributedString(string: row.name + "\t", attributes: [.font: font, .paragraphStyle: paragraph])
            var seen = Set<pid_t>()
            for window in row.windows where seen.insert(window.pid).inserted {
                guard let image = icon(window.pid) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            let item = NSMenuItem(title: row.name, action: nil, keyEquivalent: "")
            item.attributedTitle = title
            item.state = row.focused ? .on : .off
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let show = action("Show Workspace", #selector(showWorkspace(_:)))
            show.representedObject = row.name
            submenu.addItem(show)
            if !row.windows.isEmpty { submenu.addItem(.separator()) }
            for window in row.windows {
                let name = window.title.isEmpty ? window.app : window.title
                let entry = action(name.count > Self.titleLength ? name.prefix(Self.titleLength - 1) + "…" : name, #selector(focusWindow(_:)))
                entry.image = icon(window.pid)
                entry.representedObject = window.id
                entry.toolTip = window.title.isEmpty ? window.app : "\(window.app): \(window.title)"
                submenu.addItem(entry)
            }
            // Scratchpads put away pile up there: emptied in one go.
            if row.name == controller.wm.scratchpadFallbackWorkspace, !row.windows.isEmpty {
                submenu.addItem(.separator())
                let close = action("Close All Windows", #selector(closeWindows(_:)))
                close.representedObject = row.windows.map(\.id)
                submenu.addItem(close)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// With more than one display: each one, checked while the window manager uses it;
    /// unchecking it is `ignore-monitor on` (a display switched to another computer).
    private func addDisplays() {
        guard controller.isEnabled, controller.wm.focusedWorkspace != nil, case let displays = controller.wm.displays, displays.count > 1 else { return }
        let item = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for display in displays {
            let entry = action(display.name, #selector(toggleDisplay(_:)))
            entry.state = display.ignored ? .off : .on
            entry.representedObject = display.key
            submenu.addItem(entry)
        }
        item.submenu = submenu
        menu.addItem(item)
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

    @objc private func focusWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WindowID else { return }
        if let error = controller.wm.run(words: ["focus", "--window-id", String(id)]).error { HyperSpace.logger("app").error("menu: \(error)") }
    }

    @objc private func closeWindows(_ sender: NSMenuItem) {
        for id in sender.representedObject as? [WindowID] ?? [] {
            if let error = controller.wm.run(words: ["close", "--window-id", String(id)]).error { HyperSpace.logger("app").error("menu: \(error)") }
        }
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        do throws(InvalidConfig) { try controller.wm.setIgnored([key], nil) } catch { HyperSpace.logger("app").error("menu: \(error.message)") }
    }

    @objc private func toggleEnabled() { controller.setEnabled(!controller.isEnabled) }
    @objc private func grantAccessibility() { controller.openAccessibilitySettings() }
    @objc private func reloadConfig() { controller.reloadConfig() }
    @objc private func openConfig() { controller.openConfig() }
    @objc private func toggleLoginItem() { LoginItem.toggle() }
    @objc private func checkForUpdates() { Updates.check() }
    @objc private func quit() { NSApp.terminate(nil) }
}
