import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// State of the General page: startup, config file, permission and quit.
final class GeneralModel: ObservableObject {
    struct Actions {
        var openConfig: () -> Void
        /// Uses the config at a new place from now on, moving the current file there or not
        /// (`ConfigStore.relocate`).
        var relocateConfig: (_ url: URL, _ moving: Bool) throws -> Void
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
    /// The config file, as shown (with `~`).
    @Published private(set) var configPath = GeneralModel.displayPath(ConfigStore.url)
    /// Why the config could not be moved or switched: shown under the file's row.
    @Published private(set) var configLocationError: String?

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

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Asks where the config should go and moves it there (a file already there is replaced,
    /// once the panel has asked).
    func moveConfig() {
        let panel = NSSavePanel()
        panel.title = "Move Config File"
        panel.message = "HyperSpace moves its config file here and reads it from here from now on."
        panel.prompt = "Move"
        panel.nameFieldStringValue = ConfigStore.url.lastPathComponent
        panel.directoryURL = Self.suggestedFolder
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(to: url, moving: true)
    }

    /// Asks for a config file that already exists (in a dotfiles folder, say) and uses it as it is.
    func useOtherConfig() {
        let panel = NSOpenPanel()
        panel.title = "Use Another Config File"
        panel.message = "HyperSpace reads this file from now on; the current one stays where it is."
        panel.prompt = "Use"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Self.suggestedFolder
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(to: url, moving: false)
    }

    /// `~/.config/hyperspace` when it exists, else `~/.config`, else the home folder.
    private static var suggestedFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = ConfigLocation.standard(home: home).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        let config = home.appendingPathComponent(".config")
        return FileManager.default.fileExists(atPath: config.path) ? config : home
    }

    private func relocate(to url: URL, moving: Bool) {
        do {
            try actions.relocateConfig(url, moving)
            assignIfChanged(nil, to: &configLocationError)
        } catch {
            configLocationError = "The config file could not be \(moving ? "moved" : "switched"): \(error.localizedDescription)"
        }
        assignIfChanged(Self.displayPath(ConfigStore.url), to: &configPath)
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
