import AppKit
import HelmCore
import HelmIPC

/// Owns the app state: config, permission, file watcher, IPC server and menu bar item.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = Helm.logger("app")
    let configURL = ConfigLoader.defaultURL
    let accessibility = Accessibility()

    private(set) var config = Config()
    private(set) var configError: ConfigError?

    private var watcher: ConfigWatcher?
    private var server: IPCServer?
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_: Notification) {
        menu = StatusMenu(controller: self)
        reloadConfig()

        watcher = ConfigWatcher(url: configURL) { [weak self] in self?.reloadConfig() }
        watcher?.start()

        let server = IPCServer { [weak self] request in
            self?.handle(request) ?? .error("helm: shutting down")
        }
        do {
            try server.start()
            self.server = server
        } catch {
            log.error("IPC server failed to start: \(error)")
        }

        accessibility.onChange = { [weak self] granted in
            self?.log.info("Accessibility \(granted ? "granted" : "revoked")")
            self?.menu?.refresh()
        }
        if !accessibility.isGranted { accessibility.prompt() }
    }

    func applicationWillTerminate(_: Notification) {
        server?.stop()
        watcher?.stop()
    }

    // MARK: - Config

    @discardableResult
    func reloadConfig() -> Result<Config, ConfigError> {
        let result = ConfigLoader.load(from: configURL)
        switch result {
        case let .success(new):
            config = new
            configError = nil
            log.info("config loaded")
        case let .failure(error):
            // Keep running with the last good config.
            configError = error
            log.error("config error: \(error.description)")
        }
        menu?.refresh()
        return result
    }

    func openConfig() {
        do {
            NSWorkspace.shared.open(try ConfigLoader.createTemplateIfMissing(at: configURL))
        } catch {
            log.error("cannot create config: \(error)")
        }
    }

    func openAccessibilitySettings() {
        accessibility.prompt()
        NSWorkspace.shared.open(Accessibility.settingsURL)
    }

    // MARK: - helmctl

    func handle(_ request: IPC.Request) -> IPC.Response {
        switch request.args {
        case ["reload"]:
            switch reloadConfig() {
            case .success: return .ok("config reloaded")
            case let .failure(error): return .error(error.description)
            }
        case ["status"]:
            return .ok(statusText)
        case ["config-path"]:
            return .ok(configURL.path)
        case ["version"]:
            return .ok(Helm.version)
        default:
            return .error("helm: unknown command '\(request.args.joined(separator: " "))'. Run `helmctl --help`.")
        }
    }

    var statusText: String {
        """
        version        \(Helm.version)
        accessibility  \(accessibility.isGranted ? "granted" : "missing")
        config         \(configURL.path)
        config state   \(configError.map { "error: \($0.message)" } ?? "ok")
        login item     \(LoginItem.isEnabled ? "on" : "off")
        """
    }
}
