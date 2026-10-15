import AppKit
import HyperSpaceCore
import HyperSpaceInput
import HyperSpaceIPC
import HyperSpaceWM

/// Owns the app state: config, permission, file watcher, IPC server, window manager and
/// menu bar item.
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
    private(set) var wm: WindowManager!
    /// Off = every remap is undone (keyboards restored, event tap stopped) while the app stays
    /// open, so it can be turned back on from the menu or `hsctl enable`. Remembered across launches.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
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
            if let error = self?.wm.run(command) { self?.log.error("wm: \(error)") }
        }
        wm = WindowManager(handlers: .init(
            reloadConfig: { [weak self] in self?.reloadConfig() },
            enable: { [weak self] on in self?.setEnabled(on ?? !(self?.isEnabled ?? true)) },
            modeChanged: { [weak self] mode in
                self?.input.setMode(mode)
                self?.menu?.refresh()
            },
            mediaKey: { [weak self] key in _ = self?.input.run(.system(key)) },
            changed: { [weak self] in self?.menu?.refresh() }
        ))
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
        wm.stop() // brings windows of hidden workspaces back on screen
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

    /// Applies the config to the input layers and the window manager, or undoes everything
    /// while HyperSpace is disabled.
    private func applyInput() {
        let settings = config.wm.isEmpty ? nil : try? WMSettings(config.wm)
        let runWM = isEnabled && accessibility.isGranted && settings != nil
        if runWM, let settings {
            wm.start(settings)
        } else {
            wm.stop()
        }
        var trackMouse: (@MainActor @Sendable (CGPoint) -> Void)?
        if runWM, settings?.focusFollowsMouse == true {
            trackMouse = { [weak self] point in self?.wm.mouseMoved(to: point) }
        }
        input.apply(isEnabled ? plan : InputPlan(), accessibilityGranted: accessibility.isGranted, trackMouse: trackMouse)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "enabled")
        applyInput()
        log.info("HyperSpace \(enabled ? "enabled" : "disabled")")
        menu?.refresh()
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
        case ["enable"], ["disable"]:
            setEnabled(request.args == ["enable"])
            return .ok("HyperSpace \(isEnabled ? "enabled" : "disabled")")
        case ["toggle"]:
            setEnabled(!isEnabled)
            return .ok("HyperSpace \(isEnabled ? "enabled" : "disabled")")
        case let args where args.count == 2 && args[0] == "do":
            do {
                let output = try Output(parsing: args[1])
                return input.run(output) ? .ok("") : .error("hyperspace: the event tap isn't running (disabled or no Accessibility)")
            } catch {
                return .error("hyperspace: \(error.message)")
            }
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
            // Anything else is a window manager command, as with AeroSpace's CLI:
            // `hsctl workspace 2`, `hsctl list-windows --all --format '%{app-name}'`.
            let result = wm.run(words: request.args)
            if let error = result.error { return .error("hyperspace: \(error). Run `hsctl --help`.") }
            return result.ok ? .ok(result.output) : IPC.Response(exitCode: 1, stdout: result.output, stderr: "")
        }
    }

    var statusText: String {
        """
        version        \(HyperSpace.version)
        state          \(isEnabled ? "enabled" : "disabled")
        accessibility  \(accessibility.isGranted ? "granted" : "missing")
        config         \(configDirectory.path)
        config state   \(configErrors.isEmpty ? "ok" : configErrors.map { "error in \(($0.path as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n               "))
        event tap      \(input.tapState.rawValue)
        HID mappings   \(input.mappedKeyboards) keyboard(s)
        window manager \(wm.focusedWorkspace.map { "on, workspace \($0)" } ?? "off")
        login item     \(LoginItem.isEnabled ? "on" : "off")
        """
    }
}
