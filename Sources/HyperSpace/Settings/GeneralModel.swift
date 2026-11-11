import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// State of the General page: startup, config file, permission and quit.
final class GeneralModel: ObservableObject {
    struct Actions {
        var openConfig: () -> Void
        /// The current problem shown in the menu bar (config error, missing permission).
        var problem: () -> String?
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = false
    /// What needs attention: the problem shown in the menu bar, or the last action that failed here.
    @Published private(set) var problem: String?

    let actions: Actions
    private var activation: Any?

    init(actions: Actions) {
        self.actions = actions
        refresh()
        // Back from System Settings: the permission may have just been granted (and the
        // config fixed in an editor).
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    /// Each `@Published` assignment redraws the pages that show it, equal or not: only
    /// changes are assigned.
    func refresh() {
        let login = SMAppService.mainApp.status == .enabled
        if launchAtLogin != login { launchAtLogin = login }
        refreshPermission()
        let current = actions.problem()
        if problem != current { problem = current }
    }

    private func refreshPermission() {
        let granted = Permissions.isTrusted(prompt: false)
        if accessibilityGranted != granted { accessibilityGranted = granted }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            problem = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var configPath: String {
        (ConfigStore.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// How the app is doing, in a few words with a color: on the sidebar and the General page.
    var health: (text: String, color: Color) {
        if !accessibilityGranted { return (Permissions.missingShort, .orange) }
        if problem != nil { return ("Needs attention", .red) }
        return ("Running", .green)
    }
}
