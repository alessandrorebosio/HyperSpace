import AppKit

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var openSettings: () -> Void
        var workspaces: () -> [WorkspaceSummary]
        var showWorkspace: (Int) -> Void
        var focusWindow: (CGWindowID) -> Void
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

        addWorkspaces(to: menu)

        let settings = ClosureMenuItem("Settings…") { [host] in host.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

extension StatusMenu {
    /// Workspaces that have open windows, one per line: name, then the icons of their
    /// apps. A checkmark marks the ones on screen; a click shows the workspace.
    private func addWorkspaces(to menu: NSMenu) {
        let workspaces = host.workspaces().filter { !$0.windows.isEmpty }
        guard !workspaces.isEmpty else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let nameWidth = workspaces.map { ($0.name as NSString).size(withAttributes: [.font: font.bold]).width }.max() ?? 0
        let tabs = NSMutableParagraphStyle()
        tabs.tabStops = [NSTextTab(textAlignment: .left, location: nameWidth + 16)]

        for workspace in workspaces {
            let item = ClosureMenuItem(workspace.name) { [host] in host.showWorkspace(workspace.index) }
            let title = NSMutableAttributedString(string: workspace.name + "\t",
                                                  attributes: [.font: font.bold, .paragraphStyle: tabs])
            // One icon per app, in tiling order.
            var seen = Set<String>()
            for window in workspace.windows where seen.insert(window.app).inserted {
                guard let icon = window.icon?.copy() as? NSImage else { continue }
                icon.size = NSSize(width: 18, height: 18)
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: -4, width: 18, height: 18)
                title.append(NSAttributedString(attachment: attachment))
                title.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            item.attributedTitle = title
            item.toolTip = workspace.windows.map { window in
                window.title.map { "\(window.app) — \($0)" } ?? window.app
            }.joined(separator: "\n")
            item.state = workspace.display == nil ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }
}

private extension NSFont {
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
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
