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
    private var statusMenu: StatusMenu!
    private var permissionTimer: Timer?
    private var trusted = false
    private var config: Config?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu(host: StatusMenu.Host(
            tilingEnabled: { [unowned self] in windowManager.isEnabled },
            currentLayout: { [unowned self] in windowManager.currentLayout },
            perform: { [unowned self] in runner.run($0) },
            openConfig: { [unowned self] in store.openInEditor() }
        ))
        store.onChange = { [weak self] in self?.apply($0) }

        trusted = Permissions.isTrusted(prompt: true)
        if !trusted { waitForPermission() }
        // Key remapping lives in the HID layer and needs no permission, so it starts right away.
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper.reset()
    }

    /// Accessibility is granted outside the app; poll cheaply until it shows up.
    private func waitForPermission() {
        statusMenu.problem = "Accessibility permission required"
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
            remapper.apply(config.remaps)
            if trusted {
                applyTrusted(config)
                statusMenu.problem = nil
            }
            log.info("config applied")
        case .failure(let error):
            statusMenu.problem = "Config error: \(error.localizedDescription)"
            log.error("config error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The parts that need Accessibility: the event tap and window control.
    private func applyTrusted(_ config: Config) {
        eventTap.apply(config.tap)
        windowManager.apply(config.tiling)
    }
}
