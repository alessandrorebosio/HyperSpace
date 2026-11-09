import AppKit

/// Menu bar item. The menu is rebuilt lazily only when it is opened.
final class StatusMenu: NSObject, NSMenuDelegate {
    struct Host {
        var openSettings: () -> Void
        var openConfig: () -> Void
        var workspaces: () -> [WorkspaceSummary]
        var showWorkspace: (Int) -> Void
        /// Turns the tiling engine on or off (saved in the config).
        var setTilingEnabled: (Bool) -> Void
        /// Wireless keyboards, mice and trackpads with their battery level.
        var batteries: () -> [PeripheralBattery]
        var setKeyboardLocked: (Bool) -> Void
        /// When a locked keyboard unlocks by itself.
        var keyboardUnlocksAt: () -> Date?
        /// A text report of the app's state, copied to paste in a bug report.
        var debugInfo: () -> String
    }

    /// Shows a lock in the menu bar; the menu item turns into Unlock Keyboard.
    var keyboardLocked = false {
        didSet { if keyboardLocked != oldValue { updateIcon() } }
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

        /// The line in the menu: short, so a long parse error does not make the menu very wide
        /// (the whole message stays in the tooltip and in Settings).
        var menuTitle: String {
            switch self {
            case .permission: return "Accessibility permission needed"
            case .config(let message):
                let line = message.split(separator: "\n").first.map(String.init) ?? message
                return "Config error: " + (line.count > 48 ? String(line.prefix(47)) + "…" : line)
            }
        }

        var isConfig: Bool {
            if case .config = self { return true }
            return false
        }
    }

    var problem: Problem? {
        didSet { if problem != oldValue { updateIcon() } }
    }

    /// With tiling off the icon is drawn dimmed; the menu turns it back on.
    var tilingEnabled = true {
        didSet { if tilingEnabled != oldValue { updateIcon() } }
    }

    /// i3-style: the workspace shown on each display, left to right, instead of the icon.
    var workspaces: WorkspaceBar? {
        didSet { if workspaces != oldValue { updateIcon() } }
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
        button.appearsDisabled = !tilingEnabled && problem == nil && !keyboardLocked
        button.toolTip = tilingEnabled ? "HyperSpace" : "HyperSpace — tiling is off"
        button.attributedTitle = NSAttributedString()
        guard let workspaces else {
            let symbol = keyboardLocked ? "lock" : problem == nil ? "square.grid.2x2" : "exclamationmark.triangle"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HyperSpace")
            image?.isTemplate = true
            button.image = image
            return
        }
        // One template image, so it follows the menu bar's colors like the system items.
        button.image = Self.workspacesImage(names: workspaces.names, focused: workspaces.focused,
                                            locked: keyboardLocked, problem: problem != nil)
        button.imagePosition = .imageOnly
    }

    /// The workspaces left to right, the focused one in a filled box with its name cut out,
    /// like the focused workspace button of i3bar. A lock and a warning sign go before them
    /// when needed. Symbols are centered on the bar, names on their cap height (the box's middle).
    static func workspacesImage(names: [String], focused: Int, locked: Bool, problem: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let height = NSStatusBar.system.thickness
        let padding: CGFloat = 5, gap: CGFloat = 2, symbolGap: CGFloat = 4, boxHeight = min(height - 4, 18)
        let symbols = [locked ? lockImage : nil, problem ? warningImage : nil].compactMap { $0 }
        let widths = names.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
        // On whole half points, so a 2x display draws the edges sharp.
        let half = { (value: CGFloat) in (value * 2).rounded() / 2 }
        let baseline = half((height - font.capHeight) / 2)

        var width = symbols.reduce(0) { $0 + $1.size.width + symbolGap }
        width += widths.reduce(0) { $0 + $1 + padding * 2 } + gap * CGFloat(max(names.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0
            for symbol in symbols {
                // Centered by its alignment rect: the drawing, without the room below for a baseline.
                let shape = symbol.alignmentRect
                symbol.draw(in: NSRect(x: x, y: half((height - shape.height) / 2 - shape.minY),
                                       width: symbol.size.width, height: symbol.size.height))
                x += symbol.size.width + symbolGap
            }
            for (index, name) in names.enumerated() {
                let box = NSRect(x: x, y: half((height - boxHeight) / 2), width: widths[index] + padding * 2, height: boxHeight)
                // Without `.usesLineFragmentOrigin` the rect's origin is the baseline.
                let line = NSRect(x: box.minX + padding, y: baseline, width: widths[index], height: 0)
                if index == focused {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
                    context.saveGState()
                    context.setBlendMode(.destinationOut)
                    (name as NSString).draw(with: line, options: [], attributes: attributes)
                    context.restoreGState()
                } else {
                    (name as NSString).draw(with: line, options: [], attributes: attributes)
                }
                x = box.maxX + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Workspace " + (names.indices.contains(focused) ? names[focused] : "")
        return image
    }

    private static let lockImage = barSymbol("lock", description: "Keyboard locked")
    private static let warningImage = barSymbol("exclamationmark.triangle", description: "Problem")

    /// A symbol for the bar, the size of the names next to it.
    private static func barSymbol(_ name: String, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize - 1, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let problem { addProblem(problem, to: menu) }

        let enabled = tilingEnabled
        let tiling = ClosureMenuItem("Tiling") { [host] in host.setTilingEnabled(!enabled) }
        tiling.state = enabled ? .on : .off
        let hint = enabled ? "Windows are arranged in workspaces" : "Windows are left where you put them"
        let symbol = enabled ? "rectangle.split.3x1.fill" : "rectangle.split.3x1"
        tiling.styled = { Self.title("Tiling", subtitle: hint, symbol: symbol, highlighted: $0) }
        menu.addItem(tiling)
        menu.addItem(.separator())

        addWorkspaces(to: menu)
        addBatteries(to: menu)

        // Lock and Unlock share one place, so the mouse finds Unlock where it clicked Lock.
        let locked = keyboardLocked
        let left = locked ? host.keyboardUnlocksAt().map { " (\(KeyboardLock.remaining(until: $0)))" } ?? "" : ""
        let lock = ClosureMenuItem(locked ? "Unlock Keyboard" + left : "Lock Keyboard") { [host] in host.setKeyboardLocked(!locked) }
        lock.attributedTitle = Self.title(lock.title, symbol: locked ? "lock.open" : "lock")
        menu.addItem(lock)
        menu.addItem(.separator())

        let settings = ClosureMenuItem("Settings…") { [host] in host.openSettings() }
        settings.keyEquivalent = ","
        settings.attributedTitle = Self.title(settings.title, symbol: "gearshape")
        menu.addItem(settings)
        let debug = ClosureMenuItem("Copy Debug Info") { [host] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(host.debugInfo(), forType: .string)
        }
        debug.attributedTitle = Self.title(debug.title, symbol: "doc.on.doc")
        debug.toolTip = "Displays, workspaces and windows, to paste when something goes wrong"
        menu.addItem(debug)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.attributedTitle = Self.title(quit.title, symbol: "power")
        menu.addItem(quit)
    }

    /// Where the text of every item starts: the symbols sit in the slot before it.
    static let textIndent: CGFloat = 34
    private static let iconSlot: CGFloat = 24

    /// Height above the baseline of a one-line item's middle, where its icons are centered.
    /// macOS 26 and later draw an item's text low in its row: the capitals' middle sits about
    /// 1.25 pt below the row's (measured on a 2x screen). Icons centered on the capitals then
    /// look low; they go to the row's middle, like the images of the system's own menus.
    static func rowMiddle(_ font: NSFont) -> CGFloat { font.capHeight / 2 + 1.5 }
    private static let wideIconSlot: CGFloat = 28

    /// macOS 27 no longer draws `NSMenuItem.image` in this menu, so the symbol goes at the
    /// start of the title, in a fixed-width slot that keeps the text of every item aligned.
    static func title(_ text: String, symbol: String, color: NSColor = .labelColor,
                      attributes: [NSAttributedString.Key: Any] = [:]) -> NSMutableAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString()
        if let icon = symbolImage(symbol, color: color, pointSize: font.pointSize,
                                  slot: NSSize(width: iconSlot, height: 16)) {
            title.append(attachment(icon, y: rowMiddle(font) - icon.size.height / 2))
        }
        title.append(NSAttributedString(string: text, attributes: [.font: font].merging(attributes) { $1 }))
        return title
    }

    /// A title with a smaller line under it, both starting where the other items' text starts,
    /// and the symbol as tall as the two lines. An attachment cannot reach past its own line
    /// without making it taller, so the symbol is cut in two: each line holds its half and is
    /// fixed to its usual height, and the halves meet with no gap. The item stays as tall as
    /// one with a system subtitle.
    /// Its colors are set by hand, so `highlighted` turns them white under the selection.
    static func title(_ text: String, subtitle: String, symbol: String, highlighted: Bool) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let small = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        let primary: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let lineHeight = { (font: NSFont) in ceil(font.ascender - font.descender + font.leading) }
        let top = lineHeight(font), bottom = lineHeight(small)
        let icon = symbolImage(symbol, color: primary, pointSize: top + bottom,
                               slot: NSSize(width: wideIconSlot, height: top + bottom - 2))

        func line(_ string: String, font: NSFont, color: NSColor, height: CGFloat, iconFrom y: CGFloat) -> NSAttributedString {
            let line = NSMutableAttributedString()
            if let icon {
                let half = NSImage(size: NSSize(width: textIndent, height: height), flipped: false) { rect in
                    let x = (iconSlot - icon.size.width) / 2, offset = (top + bottom - icon.size.height) / 2
                    icon.draw(in: NSRect(x: x, y: offset - y, width: icon.size.width, height: icon.size.height))
                    return true
                }
                let attachment = NSTextAttachment()
                attachment.image = half
                attachment.bounds = CGRect(x: 0, y: font.descender, width: textIndent, height: height)
                line.append(NSAttributedString(attachment: attachment))
            }
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = height
            style.maximumLineHeight = height
            line.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            return line
        }

        let title = NSMutableAttributedString()
        title.append(line(text + "\n", font: font, color: primary, height: top, iconFrom: bottom))
        title.append(line(subtitle, font: small, color: secondary, height: bottom, iconFrom: 0))
        return title
    }

    /// The icon in a box `textIndent` wide, so the text after it starts at the indent.
    private static func attachment(_ icon: NSImage, y: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let box = NSImage(size: NSSize(width: textIndent, height: icon.size.height), flipped: false) { _ in
            // Centered under the narrow slot of the other items, so all the symbols line up.
            icon.draw(at: NSPoint(x: (iconSlot - icon.size.width) / 2, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        attachment.image = box
        attachment.bounds = CGRect(x: 0, y: y, width: box.size.width, height: box.size.height)
        return NSAttributedString(attachment: attachment)
    }

    /// The symbol fit and centered in `slot`, never drawn larger than `pointSize`, tinted
    /// when drawn so it follows light and dark menus.
    private static func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat, slot: NSSize) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let scale = min(1, slot.width / symbol.size.width, slot.height / symbol.size.height)
        let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let height = max(slot.height, size.height)
        return NSImage(size: NSSize(width: slot.width, height: height), flipped: false) { rect in
            let origin = NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2)
            symbol.draw(in: NSRect(origin: origin, size: size))
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Items whose colors are drawn by hand get them back in white while highlighted.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for case let styled as ClosureMenuItem in menu.items { styled.drawnHighlighted = styled === item }
    }
}

extension StatusMenu {
    /// The problem and how to fix it: a click opens the Accessibility settings or the config file.
    private func addProblem(_ problem: Problem, to menu: NSMenu) {
        let fix: String
        let item: ClosureMenuItem
        switch problem {
        case .permission:
            fix = "Click to open System Settings and allow HyperSpace"
            item = ClosureMenuItem(problem.menuTitle) { Permissions.openSettings() }
        case .config(let message):
            fix = "Click to edit the file. The last valid config stays active."
            item = ClosureMenuItem(problem.menuTitle) { [host] in host.openConfig() }
            item.toolTip = message
        }
        item.attributedTitle = Self.title(problem.menuTitle, symbol: "exclamationmark.triangle.fill", color: .systemOrange)
        if #available(macOS 14.4, *) { item.subtitle = fix } else { item.toolTip = fix }
        menu.addItem(item)
        menu.addItem(.separator())
    }

    /// Wireless input devices and their battery; a click opens the Bluetooth settings.
    private func addBatteries(to menu: NSMenu) {
        let batteries = host.batteries()
        guard !batteries.isEmpty else { return }
        if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: "Devices")) }
        for battery in batteries {
            let item = ClosureMenuItem("\(battery.name)\t\(battery.percent)%") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") { NSWorkspace.shared.open(url) }
            }
            let tabs = NSMutableParagraphStyle()
            tabs.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
            let symbol = battery.isLow ? Self.batterySymbol(battery.percent) : battery.symbol
            let title = Self.title(battery.name + "\t", symbol: symbol, color: battery.isLow ? .systemOrange : .labelColor,
                                   attributes: [.paragraphStyle: tabs])
            let level = (battery.charging ? "⚡︎ " : "") + "\(battery.percent)%"
            title.append(NSAttributedString(string: level, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: battery.isLow ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                .paragraphStyle: tabs,
            ]))
            item.attributedTitle = title
            item.toolTip = battery.isLow ? "Battery low" : nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
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
        tabs.tabStops = [NSTextTab(textAlignment: .left, location: Self.textIndent + nameWidth + 16)]

        for workspace in workspaces {
            let item = ClosureMenuItem(workspace.name) { [host] in host.showWorkspace(workspace.index) }
            let title = Self.title(workspace.name + "\t", symbol: "macwindow",
                                   attributes: [.font: font.bold, .paragraphStyle: tabs])
            // One icon per app, in tiling order.
            var seen = Set<String>()
            for window in workspace.windows where seen.insert(window.app).inserted {
                guard let icon = window.icon?.copy() as? NSImage else { continue }
                icon.size = NSSize(width: 18, height: 18)
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: (Self.rowMiddle(font) - 9).rounded(), width: 18, height: 18)
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

    /// A title that depends on whether the item is highlighted.
    var styled: ((Bool) -> NSAttributedString)? {
        didSet { drawnHighlighted = false; attributedTitle = styled?(false) }
    }

    var drawnHighlighted = false {
        didSet { if oldValue != drawnHighlighted, let styled { attributedTitle = styled(drawnHighlighted) } }
    }

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func fire() { handler() }
}
