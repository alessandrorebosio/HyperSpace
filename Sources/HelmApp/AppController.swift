import AppKit
import HelmCore
import HelmInput
import HelmIPC

/// Owns the app state: config, permission, file watcher, IPC server and menu bar item.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = Helm.logger("app")
    let configURL = ConfigLoader.defaultURL
    let accessibility = Accessibility()

    private(set) var config = Config()
    /// `config` compiled; recompiled only when the config changes.
    private var plan = InputPlan()
    private(set) var configError: ConfigError?
    private(set) var input: InputService!
    private var signalSources: [any DispatchSourceSignal] = []

    private var watcher: ConfigWatcher?
    private var server: IPCServer?
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_: Notification) {
        // Two instances would fight over the event tap, the HID mappings and the socket.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Helm.bundleID)
            .filter { $0 != .current }
        if !others.isEmpty {
            log.info("Helm is already running (pid \(others[0].processIdentifier)), exiting")
            exit(0)
        }

        input = InputService { [weak self] command in
            self?.log.info("WM command '\(command)' ignored: the window manager isn't implemented yet")
        }
        terminateOnSignals()
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
            self?.applyInput()
            self?.menu?.refresh()
        }
        if !accessibility.isGranted { accessibility.prompt() }
    }

    func applicationWillTerminate(_: Notification) {
        input.shutdown() // restores the keyboards' original HID mappings
        server?.stop()
        watcher?.stop()
    }

    /// `kill`/Ctrl-C must also go through `applicationWillTerminate`, otherwise Caps Lock
    /// would stay remapped to F18 until the next reboot.
    private func terminateOnSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func applyInput() {
        input.apply(plan, accessibilityGranted: accessibility.isGranted)
    }

    // MARK: - Config

    @discardableResult
    func reloadConfig() -> Result<Config, ConfigError> {
        let result = ConfigLoader.load(from: configURL)
        switch result {
        case let .success(new):
            config = new
            plan = (try? InputPlan(new)) ?? InputPlan() // validated by the loader: can't fail
            configError = nil
            log.info("config loaded")
            applyInput()
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
            accessibility.refresh()
            return .ok(statusText)
        case ["config-path"]:
            return .ok(configURL.path)
        case ["version"]:
            return .ok(Helm.version)
        case ["apps"]:
            // Bundle ids for [[keyboard.capslock.app]] and [[mouse.app]].
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? "?", $0) } }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            let width = apps.map(\.0.count).max() ?? 0
            return .ok(apps.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n"))
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
        event tap      \(input.tapState.rawValue)
        HID mappings   \(input.mappedKeyboards) keyboard(s)
        login item     \(LoginItem.isEnabled ? "on" : "off")
        """
    }
}
