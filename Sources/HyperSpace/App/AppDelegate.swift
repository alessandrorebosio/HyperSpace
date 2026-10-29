import AppKit
import os

let log = Logger(subsystem: "com.alessandrorebosio.HyperSpace", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let remapper = KeyboardRemapper()
    private let windowManager = WindowManager()
    private lazy var runner = ActionRunner(windowManager: windowManager) { [weak self] in
        self?.store.reload()
    }
    private lazy var eventTap = EventTap(drag: DragController(windowManager: windowManager)) { [weak self] action in
        self?.runner.run(action)
    }
    private lazy var settingsWindow = SettingsWindowController(
        remapper: remapper, eventTap: eventTap,
        actions: GeneralModel.Actions(
            openConfig: { [unowned self] in store.openInEditor() },
            problem: { [unowned self] in statusMenu.problem?.text }
        )
    )
    private var statusMenu: StatusMenu!
    private var permissionTimer: Timer?
    private var trusted = false
    private var config: Config?

    /// Opened by macOS at login rather than by the user.
    private var launchedAtLogin = false
    private var firstConfig = true

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only readable here: the open-application event says whether it is a login launch.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Double-clicking the app while it runs opens Settings (the only way with tiling off,
    /// when there is no menu bar item).
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
            focusWindow: { [unowned self] in windowManager.focusWindow($0) },
            layout: { [unowned self] in windowManager.activeLayout },
            setLayout: { [unowned self] in windowManager.setLayout($0) },
            setKeyboardLocked: { [unowned self] in eventTap.setKeyboardLocked($0) },
            keyboardUnlocksAt: { [unowned self] in eventTap.keyboardUnlocksAt },
            debugInfo: { [unowned self] in debugInfo() }
        ))
        NotificationCenter.default.addObserver(forName: EventTap.keyboardLockDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            statusMenu.keyboardLocked = eventTap.isKeyboardLocked
        }
        store.onChange = { [weak self] in self?.apply($0) }
        windowManager.onWorkspaceChange = { [weak self] in self?.statusMenu.workspaces = $0 }
        windowManager.onEnabledChange = { [weak self] in self?.statusMenu.tilingEnabled = $0 }
        // At login macOS reopens apps for a while (also after a logout, unlike a boot check).
        if launchedAtLogin { windowManager.revealAfter = Date().addingTimeInterval(90) }

        trusted = Permissions.isTrusted(prompt: true)
        if !trusted { waitForPermission() }
        // Key remapping lives in the HID layer and needs no permission, so it starts right away.
        store.start()
    }

    @objc private func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    private func debugInfo() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var lines = [
            "HyperSpace \(version) — \(Date().formatted(date: .numeric, time: .standard))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), up \(Int(ProcessInfo.processInfo.systemUptime / 60)) min",
            "Accessibility: \(Permissions.isTrusted(prompt: false) ? "granted" : "missing"), launched at login: \(launchedAtLogin)",
            "Keyboard: \(eventTap.isKeyboardLocked ? "locked" : "active"); keyboards: " +
                remapper.connectedKeyboards().map { $0.product.isEmpty ? "?" : $0.product }.joined(separator: ", "),
        ]
        if let problem = statusMenu.problem { lines.append("Problem: \(problem.text)") }
        lines.append(windowManager.debugReport())
        return lines.joined(separator: "\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper.reset()
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
            // Opened by hand with no menu bar item to show for it: show Settings instead.
            if firstConfig, !config.tiling.enabled, !launchedAtLogin { settingsWindow.show() }
            firstConfig = false
            remapper.apply(config.remaps)
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
