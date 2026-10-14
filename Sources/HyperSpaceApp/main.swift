import AppKit

let app = NSApplication.shared
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
