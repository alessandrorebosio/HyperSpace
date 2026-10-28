import AppKit
import os

let log = Logger(subsystem: "com.alessandrorebosio.HyperSpace", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let remapper = HIDKeyRemapper()
    private let windowManager = WindowManager()
    private lazy var runner = ActionRunner(windowManager: windowManager) { [weak self] in
        self?.store.reload()
    }
    private lazy var eventTap = EventTap(drag: DragController(windowManager: windowManager)) { [weak self] action in
        self?.runner.run(action)
    }
    private var statusMenu: StatusMenu!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu(host: StatusMenu.Host(
            tilingEnabled: { [unowned self] in windowManager.isEnabled },
            currentLayout: { [unowned self] in windowManager.currentLayout },
            perform: { [unowned self] in runner.run($0) },
            openConfig: { [unowned self] in store.openInEditor() }
        ))
        store.onChange = { [weak self] in self?.apply($0) }

        if Permissions.isTrusted(prompt: true) {
            start()
        } else {
            waitForPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remapper.reset()
    }

    /// Accessibility is granted outside the app; poll cheaply until it shows up.
    private func waitForPermission() {
        statusMenu.problem = "Accessibility permission required"
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard Permissions.isTrusted(prompt: false) else { return }
            timer.invalidate()
            self?.permissionTimer = nil
            self?.statusMenu.problem = nil
            self?.start()
        }
    }

    private func start() {
        _ = eventTap
        store.start()
    }

    private func apply(_ result: Result<Config, Error>) {
        switch result {
        case .success(let config):
            remapper.apply(config.hidRemaps)
            eventTap.apply(config.tap)
            windowManager.apply(config.tiling)
            statusMenu.problem = nil
            log.info("config applied")
        case .failure(let error):
            statusMenu.problem = "Config error: \(error.localizedDescription)"
            log.error("config error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
