import AppKit

/// The menu bar shown while the settings window makes HyperSpace a regular app. It also
/// gives the window the usual key equivalents: ⌘W, ⌘Q, copy and paste in text fields.
enum MainMenu {
    static func make(settings: Selector, target: AnyObject) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "HyperSpace")
        app.addItem(withTitle: "About HyperSpace", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: settings, keyEquivalent: ",").target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Hide HyperSpace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit HyperSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
