import AppKit

/// Executes actions on the main thread.
final class ActionRunner {
    private let windowManager: WindowManager
    private let reload: () -> Void
    private var children: Set<Process> = []

    init(windowManager: WindowManager, reload: @escaping () -> Void) {
        self.windowManager = windowManager
        self.reload = reload
    }

    func run(_ action: Action) {
        switch action {
        case .focus(let dir): windowManager.focus(dir)
        case .swap(let dir): windowManager.swap(dir)
        case .swapMaster: windowManager.swapMaster()
        case .setLayout(let kind): windowManager.setLayout(kind)
        case .nextLayout: windowManager.nextLayout()
        case .adjustRatio(let delta): windowManager.adjustRatio(CGFloat(delta))
        case .toggleFloat: windowManager.toggleFloat()
        case .toggleTiling: windowManager.toggleEnabled()
        case .retile: windowManager.retileNow()
        case .moveToNextDisplay: windowManager.moveToNextDisplay()
        case .launch(let app): launch(app)
        case .shell(let command): shell(command)
        case .sendKey(let combo): KeyEmitter.post(combo)
        case .reload: reload()
        case .none: break
        }
    }

    /// Accepts a bundle identifier ("com.apple.Terminal") or an app name ("Terminal").
    private func launch(_ name: String) {
        let workspace = NSWorkspace.shared
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        let url = workspace.urlForApplication(withBundleIdentifier: name)
            ?? folders.lazy
                .map { URL(fileURLWithPath: "\($0)/\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else {
            log.error("launch: app not found: \(name, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func shell(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { self?.children.remove(finished) }
        }
        do {
            try process.run()
            children.insert(process)
        } catch {
            log.error("shell failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
