import AppKit
import ApplicationServices

/// Accessibility is the only permission HyperSpace needs: it covers active
/// event taps (read + modify input), posting synthetic events and AX window control.
enum Permissions {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
