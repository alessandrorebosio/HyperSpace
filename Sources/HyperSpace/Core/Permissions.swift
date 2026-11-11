import AppKit

/// Accessibility is the only permission HyperSpace needs: it covers active
/// event taps (read + modify input), posting synthetic events and AX window control.
enum Permissions {
    /// The words for a missing permission, the same everywhere: a title, and a few words for
    /// tight places (the sidebar status).
    static let missingTitle = "Accessibility permission needed"
    static let missingShort = "Accessibility needed"

    static func isTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
