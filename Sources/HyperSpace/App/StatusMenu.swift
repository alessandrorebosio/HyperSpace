import AppKit

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var openSettings: () -> Void
        var openConfig: () -> Void
        var workspaces: () -> [WorkspaceSummary]
        var showWorkspace: (Int) -> Void
        var focusWindow: (CGWindowID) -> Void
        /// Layout of the focused display, nil while tiling is off.
        var layout: () -> LayoutKind?
        var setLayout: (LayoutKind) -> Void
        var setKeyboardLocked: (Bool) -> Void
        /// When a locked keyboard unlocks by itself.
        var keyboardUnlocksAt: () -> Date?
        /// A text report of the app's state, copied to paste in a bug report.
        var debugInfo: () -> String
    }

    /// Shows a lock in the menu bar; the menu item turns into Unlock Keyboard.
    var keyboardLocked = false {
        didSet { updateIcon() }
    }

    /// Something that keeps HyperSpace from working fully, shown at the top of the menu.
    enum Problem: Equatable {
        case permission
        case config(String)

        var text: String {
            switch self {
            case .permission: return "Accessibility not granted to this build"
            case .config(let message): return "Config error: \(message)"
            }
        }

        var isConfig: Bool {
            if case .config = self { return true }
            return false
        }
    }

    var problem: Problem? {
        didSet { updateIcon() }
    }

    /// With tiling off the menu bar item is gone (double-click the app to open Settings),
    /// unless there is a problem to report or the keyboard is locked and needs Unlock.
    var tilingEnabled = true {
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
        item.isVisible = tilingEnabled || problem != nil || keyboardLocked
        guard let button = item.button else { return }
        guard let workspaces else {
            let symbol = keyboardLocked ? "lock" : problem == nil ? "square.grid.2x2" : "exclamationmark.triangle"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HyperSpace")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString()
            return
        }
        // A thin template lock before the workspaces, drawn like the rest of the menu bar.
        button.image = keyboardLocked ? Self.lockImage : nil
        button.imagePosition = .imageLeading
        let size = NSFont.systemFontSize
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)]
        let title = NSMutableAttributedString(string: (keyboardLocked ? " " : "") + (problem == nil ? "" : "⚠︎ "), attributes: regular)
        for (index, name) in workspaces.names.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: " | ", attributes: regular)) }
            // With several displays the focused one is bold.
            let focused = workspaces.names.count > 1 && index == workspaces.focused
            title.append(NSAttributedString(string: name, attributes: focused ? bold : regular))
        }
        button.attributedTitle = title
    }

    private static let lockImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize - 1, weight: .medium)
        let image = NSImage(systemSymbolName: "lock", accessibilityDescription: "Keyboard locked")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let problem { addProblem(problem, to: menu) }

        addWorkspaces(to: menu)
        addLayouts(to: menu)

        // Lock and Unlock share one place, so the mouse finds Unlock where it clicked Lock.
        let locked = keyboardLocked
        let left = locked ? host.keyboardUnlocksAt().map { " (\(KeyboardLock.remaining(until: $0)))" } ?? "" : ""
        let lock = ClosureMenuItem(locked ? "Unlock Keyboard" + left : "Lock Keyboard") { [host] in host.setKeyboardLocked(!locked) }
        lock.image = Self.symbol(locked ? "lock.open" : "lock")
        menu.addItem(lock)
        menu.addItem(.separator())

        let settings = ClosureMenuItem("Settings…") { [host] in host.openSettings() }
        settings.keyEquivalent = ","
        settings.image = Self.symbol("gearshape")
        menu.addItem(settings)
        let debug = ClosureMenuItem("Copy Debug Info") { [host] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.debugInfo(), forType: .string)
        }
        debug.image = Self.symbol("doc.on.doc")
        debug.toolTip = "Displays, workspaces and windows, to paste when something goes wrong"
        menu.addItem(debug)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("power")
        menu.addItem(quit)
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

extension StatusMenu {
    /// The problem and how to fix it: a click opens the Accessibility settings or the config file.
    private func addProblem(_ problem: Problem, to menu: NSMenu) {
        let fix: String
        let item: ClosureMenuItem
        switch problem {
        case .permission:
            fix = "Click to allow HyperSpace in System Settings"
            item = ClosureMenuItem(problem.text) { Permissions.openSettings() }
        case .config(let message):
            fix = "Click to edit the file. The last valid config stays active."
            item = ClosureMenuItem(problem.text) { [host] in host.openConfig() }
            item.toolTip = message
        }
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Problem")
        item.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
        if #available(macOS 14.4, *) { item.subtitle = fix } else { item.toolTip = fix }
        menu.addItem(item)
        menu.addItem(.separator())
    }

    /// The layouts, with a checkmark on the one of the focused display.
    private func addLayouts(to menu: NSMenu) {
        guard let current = host.layout() else { return }
        let submenu = NSMenu()
        for kind in LayoutKind.allCases {
            let option = ClosureMenuItem(kind.rawValue.capitalized) { [host] in host.setLayout(kind) }
            option.state = kind == current ? .on : .off
            submenu.addItem(option)
        }
        let item = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        item.image = Self.symbol("rectangle.split.3x1")
        item.submenu = submenu
        menu.addItem(item)
        menu.addItem(.separator())
    }

    /// Workspaces that have open windows, one per line: name, then the icons of their
    /// apps. A checkmark marks the ones on screen; a click shows the workspace.
    private func addWorkspaces(to menu: NSMenu) {
        let workspaces = host.workspaces().filter { !$0.windows.isEmpty }
        guard !workspaces.isEmpty else { return }
        if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: "Workspaces")) }
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
