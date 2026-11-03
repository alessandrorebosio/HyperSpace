import AppKit

let app = NSApplication.shared

// Debug: draw the settings pages to PNG files and quit, without starting anything else.
if let folder = SettingsSnapshot.folder(arguments: CommandLine.arguments) {
    app.setActivationPolicy(.accessory)
    exit(SettingsSnapshot.render(into: folder))
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
