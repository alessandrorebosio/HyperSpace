import Foundation
import HelmCore
import ServiceManagement

/// Launch at login through `SMAppService` (no hand-written LaunchAgent).
/// Only works when running from an app bundle.
@MainActor
enum LoginItem {
    private static let log = Helm.logger("login-item")

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log.error("login item toggle failed: \(error)")
        }
    }
}
