import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// State of the General page: startup, config file, permission and quit.
final class GeneralModel: ObservableObject {
    struct Actions {
        var openConfig: () -> Void
        /// The config error shown in the menu bar, if any.
        var configProblem: () -> String?
    }

    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityGranted = false
    /// The config error shown in the menu bar, if any.
    @Published private(set) var configProblem: String?
    /// Why Launch at login could not be changed: shown under its switch only, not part of the
    /// app's health (the app itself works).
    @Published private(set) var loginError: String?

    let actions: Actions
    private var activation: Any?

    init(actions: Actions) {
        self.actions = actions
        refresh()
        // Back from System Settings: the permission may have just been granted, or Launch at
        // login changed there.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    /// Everything the page shows from outside the file: on opening and on activation only, since
    /// the login item and the permission are system calls.
    func refresh() {
        assignIfChanged(SMAppService.mainApp.status == .enabled, to: &launchAtLogin)
        assignIfChanged(Permissions.isTrusted(prompt: false), to: &accessibilityGranted)
        refreshConfigProblem()
    }

    /// The config was loaded (a cheap closure): its error, or none.
    func refreshConfigProblem() {
        assignIfChanged(actions.configProblem(), to: &configProblem)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            assignIfChanged(nil, to: &loginError)
        } catch {
            loginError = "Launch at login could not be changed: \(error.localizedDescription)"
        }
        assignIfChanged(SMAppService.mainApp.status == .enabled, to: &launchAtLogin)
    }

    var configPath: String {
        (ConfigStore.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// How the app is doing, in a few words with a color: on the sidebar and the General page.
    var health: (text: String, color: Color) {
        Self.health(accessibilityGranted: accessibilityGranted, configProblem: configProblem != nil)
    }

    static func health(accessibilityGranted: Bool, configProblem: Bool) -> (text: String, color: Color) {
        if !accessibilityGranted { return (Permissions.missingShort, .orange) }
        if configProblem { return ("Needs attention", .red) }
        return ("Running", .green)
    }
}
