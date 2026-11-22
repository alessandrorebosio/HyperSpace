import AppKit
import Combine
import ServiceManagement

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
    @Published private(set) var configPath = ConfigStore.url.abbreviatedPath
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

    /// The config file itself, for the panels that ask where it should go.
    var configURL: URL { ConfigStore.url }

    /// `~/.config/hyperspace` when it exists, else `~/.config`, else the home folder: where the
    /// panels that move or pick the config start.
    static var suggestedFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = ConfigLocation.standard(home: home).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        let config = home.appendingPathComponent(".config")
        return FileManager.default.fileExists(atPath: config.path) ? config : home
    }

    func showConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
    }

    func openAccessibilitySettings() {
        Permissions.openSettings()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Uses the config at `url` from now on: `moving`, the current file goes there first (a
    /// file already there is replaced, once the panel has asked); otherwise the file there is
    /// read as it is.
    func relocate(to url: URL, moving: Bool) {
        do {
            try actions.relocateConfig(url, moving)
            assignIfChanged(nil, to: &configLocationError)
        } catch {
            configLocationError = "The config file could not be \(moving ? "moved" : "switched"): \(error.localizedDescription)"
        }
        assignIfChanged(ConfigStore.url.abbreviatedPath, to: &configPath)
    }

    /// How the app is doing: on the sidebar and the General page, which give it its color.
    enum Health: Equatable {
        case running
        /// The Accessibility permission is missing (it comes before a config error).
        case permissionMissing
        case configProblem

        var text: String {
            switch self {
            case .running: return "Running"
            case .permissionMissing: return Permissions.missingShort
            case .configProblem: return "Needs attention"
            }
        }
    }

    var health: Health {
        Self.health(accessibilityGranted: accessibilityGranted, configProblem: configProblem != nil)
    }

    static func health(accessibilityGranted: Bool, configProblem: Bool) -> Health {
        if !accessibilityGranted { return .permissionMissing }
        return configProblem ? .configProblem : .running
    }
}
