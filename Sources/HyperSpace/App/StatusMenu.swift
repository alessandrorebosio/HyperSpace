import AppKit

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var openSettings: () -> Void
    }

    /// Shown at the top of the menu (missing permission, config error).
    var problem: String? {
        didSet { updateIcon() }
    }

    /// i3-style: the workspace shown on each display, left to right, instead of the icon.
    var workspaces: (names: [String], focused: Int)? {
        didSet { updateIcon() }
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        guard let button = item.button else { return }
        guard let workspaces else {
            let symbol = problem == nil ? "square.grid.2x2" : "exclamationmark.triangle"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HyperSpace")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString()
            return
        }
        button.image = nil
        let size = NSFont.systemFontSize
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)]
        let title = NSMutableAttributedString(string: problem == nil ? "" : "⚠︎ ", attributes: regular)
        for (index, name) in workspaces.names.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: " | ", attributes: regular)) }
            // With several displays the focused one is bold.
            let focused = workspaces.names.count > 1 && index == workspaces.focused
            title.append(NSAttributedString(string: name, attributes: focused ? bold : regular))
        }
        button.attributedTitle = title
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
