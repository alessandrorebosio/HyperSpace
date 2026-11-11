import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let remapper = KeyboardRemapper()
    private let windowManager = WindowManager()
    /// The tap is captured here, on the main thread: the hold is set from the multitouch thread.
    private lazy var edgeSliders = EdgeSliders { [eventTap] held in eventTap.setPointerHeld(held) }
    private lazy var overview = WorkspaceOverview(host: WorkspaceOverview.Host(
        workspaces: { [unowned self] in windowManager.summaries() },
        focused: { [unowned self] in windowManager.focusedWorkspace },
        switchKeys: { [unowned self] in config?.tiling.switchKeys ?? [:] }
    ))
    private lazy var runner = ActionRunner(
        windowManager: windowManager, overview: overview,
        reload: { [weak self] in self?.store.reload() },
        toggleTiling: { [weak self] in
            guard let self else { return }
            setTilingEnabled(!statusMenu.tilingEnabled)
        }
    )
    private lazy var eventTap = EventTap(
        drag: DragController(windowManager: windowManager),
        onAction: { [weak self] action in self?.runner.run(action) },
        onOverview: { [weak self] shown in
            guard let self else { return }
            if shown { overview.show() } else { overview.hide() }
        }
    )
    private lazy var settingsWindow = SettingsWindowController(
        remapper: remapper, eventTap: eventTap,
        actions: GeneralModel.Actions(
            openConfig: { [unowned self] in store.openInEditor() },
            problem: { [unowned self] in statusMenu.problem?.text }
        )
    )
    private var statusMenu: StatusMenu!
    private var permissionTimer: Timer?
    /// SIGTERM and SIGINT (`killall`, a logout script) quit like the menu does, so the key
    /// remaps are reset and parked windows come back.
    private var signalSources: [DispatchSourceSignal] = []
    private var trusted = false
    private var config: Config?

    /// Opened by macOS at login rather than by the user.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only readable here: the open-application event says whether it is a login launch.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Double-clicking the app while it runs opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(settings: #selector(showSettings(_:)), target: self)
        statusMenu = StatusMenu(host: StatusMenu.Host(
            openSettings: { [unowned self] in settingsWindow.show() },
            openConfig: { [unowned self] in store.openInEditor() },
            workspaces: { [unowned self] in windowManager.summaries() },
            showWorkspace: { [unowned self] in windowManager.switchWorkspace($0) },
            setTilingEnabled: { [unowned self] in setTilingEnabled($0) },
            batteries: { Peripherals.batteries() },
            setKeyboardLocked: { [unowned self] in eventTap.setKeyboardLocked($0) },
            keyboardUnlocksAt: { [unowned self] in eventTap.keyboardUnlocksAt },
            debugInfo: { [unowned self] in debugInfo() }
        ))
        NotificationCenter.default.addObserver(forName: EventTap.keyboardLockDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            statusMenu.keyboardLocked = eventTap.isKeyboardLocked
        }
        store.onChange = { [weak self] in self?.apply($0) }
        windowManager.onWorkspaceChange = { [weak self] in
            self?.statusMenu.workspaces = $0
            self?.overview.refresh()
        }
        windowManager.onEnabledChange = { [weak self] in self?.statusMenu.tilingEnabled = $0 }
        // At login macOS reopens apps for a while (also after a logout, unlike a boot check).
        if launchedAtLogin { windowManager.revealAfter = Date().addingTimeInterval(90) }

        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        trusted = Permissions.isTrusted(prompt: true)
        if !trusted { waitForPermission() }
        // Key remapping lives in the HID layer and needs no permission, so it starts right away.
        store.start()
    }

    /// From the menu bar or the `tiling` action: saved in the config, so it lasts and an open
    /// Settings window follows. The reload that follows the write applies it.
    private func setTilingEnabled(_ on: Bool) {
        if let error = ConfigWriter.save(section: "tiling", { $0["enabled"] = on }) {
            // The file cannot be written (a syntax error): tiling still follows, until a reload.
            statusMenu.problem = .config(error)
            windowManager.setEnabled(on)
            return
        }
        statusMenu.tilingEnabled = on
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    private func debugInfo() -> String {
        var lines = [
            "HyperSpace \(AppInfo.version) — \(Date().formatted(date: .numeric, time: .standard))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), up \(Int(ProcessInfo.processInfo.systemUptime / 60)) min",
            "Accessibility: \(Permissions.isTrusted(prompt: false) ? "granted" : "missing"), launched at login: \(launchedAtLogin)",
            "Devices: " + (Peripherals.batteries().map { "\($0.name) \($0.percent)%\($0.charging ? " charging" : "")" }.joined(separator: ", ").nilIfEmpty ?? "none with a battery"),
            "Keyboard: \(eventTap.isKeyboardLocked ? "locked" : "active"); keyboards: " +
                remapper.connectedKeyboards().map { $0.product.isEmpty ? "?" : $0.product }.joined(separator: ", "),
        ]
        let trackpad = config?.trackpad ?? TrackpadConfig()
        lines.append(trackpad.edgeSliders
            ? "Trackpad edge sliders: left \(trackpad.leftEdge.rawValue), right \(trackpad.rightEdge.rawValue); "
                + (edgeSliders.isAvailable ? "\(edgeSliders.deviceCount) trackpad(s)" : "MultitouchSupport not available")
            : "Trackpad edge sliders: off")
        if let problem = statusMenu.problem { lines.append("Problem: \(problem.text)") }
        lines.append(windowManager.debugReport())
        return lines.joined(separator: "\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper.reset()
        edgeSliders.stop()
        windowManager.saveState()
        windowManager.restoreHiddenWindows()
    }

    /// Accessibility is granted outside the app; poll cheaply until it shows up.
    private func waitForPermission() {
        statusMenu.problem = .permission
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, Permissions.isTrusted(prompt: false) else { return }
            timer.invalidate()
            permissionTimer = nil
            trusted = true
            statusMenu.problem = nil
            if let config { applyTrusted(config) }
        }
    }

    private func apply(_ result: Result<Config, Error>) {
        switch result {
        case .success(let config):
            self.config = config
            statusMenu.tilingEnabled = config.tiling.enabled
            remapper.apply(config.remaps)
            edgeSliders.apply(config.trackpad)
            if config.tap.suppressCapsLock { CapsLock.turnOff() }
            if trusted { applyTrusted(config) }
            // A missing permission stays reported until it is granted.
            if trusted || statusMenu.problem?.isConfig == true { statusMenu.problem = nil }
            log.info("config applied")
        case .failure(let error):
            statusMenu.problem = .config(error.localizedDescription)
            log.error("config error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The parts that need Accessibility: the event tap and window control.
    private func applyTrusted(_ config: Config) {
        eventTap.apply(config.tap)
        windowManager.apply(config.tiling)
    }
}
