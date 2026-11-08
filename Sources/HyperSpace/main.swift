import AppKit

let app = NSApplication.shared
// Info.plist says so too (LSUIElement); this covers `swift run`, which has no bundle.
app.setActivationPolicy(.accessory)

// Debug: draw the settings pages to PNG files and quit, without starting anything else.
if let folder = SettingsSnapshot.folder(arguments: CommandLine.arguments) {
    exit(SettingsSnapshot.render(into: folder))
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
