import AppKit
import ServiceManagement

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var openSettings: () -> Void
        var openConfig: () -> Void
        var reloadConfig: () -> Void
    }

    /// Shown at the top of the menu (missing permission, config error).
    var problem: String? {
        didSet { updateIcon() }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let host: Host

    init(host: Host) {
        self.host = host
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let symbol = problem == nil ? "square.grid.2x2" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HyperSpace")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let problem {
            menu.addItem(ClosureMenuItem("⚠︎ \(problem)") { Permissions.openSettings() })
            menu.addItem(.separator())
        }

        let settings = ClosureMenuItem("Settings…") { [host] in host.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(ClosureMenuItem("Edit Config…") { [host] in host.openConfig() })
        menu.addItem(ClosureMenuItem("Reload Config") { [host] in host.reloadConfig() })

        let login = ClosureMenuItem("Launch at Login") { Self.toggleLaunchAtLogin() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.error("launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}
