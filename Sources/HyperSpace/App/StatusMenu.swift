import AppKit
import ServiceManagement

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var tilingEnabled: () -> Bool
        var currentLayout: () -> LayoutKind
        var perform: (Action) -> Void
        var openConfig: () -> Void
        var openRemapper: () -> Void
    }

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
            let warning = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let remap = ClosureMenuItem("Keyboard Remapping…") { [host] in host.openRemapper() }
        remap.keyEquivalent = ","
        menu.addItem(remap)
        menu.addItem(.separator())

        let tiling = ClosureMenuItem("Tiling") { [host] in host.perform(.toggleTiling) }
        tiling.state = host.tilingEnabled() ? .on : .off
        menu.addItem(tiling)

        let layouts = NSMenu()
        let current = host.currentLayout()
        for kind in LayoutKind.allCases {
            let entry = ClosureMenuItem(kind.rawValue.capitalized) { [host] in host.perform(.setLayout(kind)) }
            entry.state = kind == current ? .on : .off
            layouts.addItem(entry)
        }
        let layoutItem = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layoutItem.submenu = layouts
        menu.addItem(layoutItem)
        menu.addItem(ClosureMenuItem("Retile Now") { [host] in host.perform(.retile) })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Edit Config…") { [host] in host.openConfig() })
        menu.addItem(ClosureMenuItem("Reload Config") { [host] in host.perform(.reload) })
        menu.addItem(ClosureMenuItem("Accessibility Settings…") { Permissions.openSettings() })

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
