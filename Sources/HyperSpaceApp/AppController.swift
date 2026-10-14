import AppKit
import HyperSpaceCore
import HyperSpaceInput
import HyperSpaceIPC

/// Owns the app state: config, permission, file watcher, IPC server and menu bar item.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let log = HyperSpace.logger("app")
    let configDirectory = ConfigLoader.defaultDirectory
    let accessibility = Accessibility()

    private(set) var config = Config()
    /// `config` compiled; recompiled only when the config changes.
    private var plan = InputPlan()
    /// One per broken file; those files keep their last good settings.
    private(set) var configErrors: [ConfigError] = []
    private(set) var input: InputService!
    private var signalSources: [any DispatchSourceSignal] = []

    private var watcher: ConfigWatcher?
    private var server: IPCServer?
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_: Notification) {
        // Two instances would fight over the event tap, the HID mappings and the socket.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: HyperSpace.bundleID)
            .filter { $0 != .current }
        if !others.isEmpty {
            log.info("HyperSpace is already running (pid \(others[0].processIdentifier)), exiting")
            exit(0)
        }

        input = InputService { [weak self] command in
            self?.log.info("WM command '\(command)' ignored: the window manager isn't implemented yet")
        }
        terminateOnSignals()
        menu = StatusMenu(controller: self)
        reloadConfig()

        let files = ConfigFile.allCases.map { ConfigLoader.url($0, in: configDirectory) }
        watcher = ConfigWatcher(directory: configDirectory, files: files) { [weak self] in self?.reloadConfig() }
        watcher?.start()

        let server = IPCServer { [weak self] request in
            self?.handle(request) ?? .error("hyperspace: shutting down")
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

    /// Reloads every config file; broken files keep their last good settings.
    @discardableResult
    func reloadConfig() -> [ConfigError] {
        let (new, errors) = ConfigLoader.load(from: configDirectory, previous: config)
        configErrors = errors
        for error in errors { log.error("config error: \(error.description)") }
        config = new
        plan = (try? InputPlan(new)) ?? InputPlan() // validated by the loader: can't fail
        applyInput()
        log.info("config loaded")
        menu?.refresh()
        return errors
    }

    /// Creates any missing file from its template and opens all three.
    func openConfig() {
        do {
            for url in try ConfigLoader.createTemplatesIfMissing(in: configDirectory) { NSWorkspace.shared.open(url) }
        } catch {
            log.error("cannot create config: \(error)")
        }
    }

    func openAccessibilitySettings() {
        accessibility.prompt()
        NSWorkspace.shared.open(Accessibility.settingsURL)
    }

    // MARK: - hsctl

    func handle(_ request: IPC.Request) -> IPC.Response {
        switch request.args {
        case ["reload"]:
            let errors = reloadConfig()
            return errors.isEmpty ? .ok("config reloaded") : .error(errors.map(\.description).joined(separator: "\n"))
        case ["status"]:
            accessibility.refresh()
            return .ok(statusText)
        case ["config-path"]:
            return .ok(configDirectory.path)
        case ["version"]:
            return .ok(HyperSpace.version)
        case ["apps"]:
            // Bundle ids for [[capslock.app]] in keyboard.toml and [[app]] in mouse.toml.
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? "?", $0) } }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
            let width = apps.map(\.0.count).max() ?? 0
            return .ok(apps.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n"))
        default:
            return .error("hyperspace: unknown command '\(request.args.joined(separator: " "))'. Run `hsctl --help`.")
        }
    }

    var statusText: String {
        """
        version        \(HyperSpace.version)
        accessibility  \(accessibility.isGranted ? "granted" : "missing")
        config         \(configDirectory.path)
        config state   \(configErrors.isEmpty ? "ok" : configErrors.map { "error in \(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n               "))
        event tap      \(input.tapState.rawValue)
        HID mappings   \(input.mappedKeyboards) keyboard(s)
        login item     \(LoginItem.isEnabled ? "on" : "off")
        """
    }
}
