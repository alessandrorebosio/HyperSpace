import AppKit

/// Executes actions on the main thread.
final class ActionRunner {
    private let windowManager: WindowManager
    private let reload: () -> Void
    /// Turns tiling on or off the way the menu bar does: saved in the config.
    private let toggleTiling: () -> Void
    private let overview: WorkspaceOverview
    private var children: Set<Process> = []

    init(windowManager: WindowManager, overview: WorkspaceOverview, reload: @escaping () -> Void,
         toggleTiling: @escaping () -> Void) {
        self.windowManager = windowManager
        self.overview = overview
        self.reload = reload
        self.toggleTiling = toggleTiling
    }

    func run(_ action: Action) {
        switch action {
        case .focus(let dir): windowManager.focus(dir)
        case .swap(let dir): windowManager.swap(dir)
        case .swapMaster: windowManager.swapMaster()
        case .setLayout(let kind): windowManager.setLayout(kind)
        case .adjustRatio(let delta): windowManager.adjustRatio(CGFloat(delta))
        case .toggleFloat: windowManager.toggleFloat()
        case .toggleTiling: toggleTiling()
        case .toggleAccordion: windowManager.toggleAccordion()
        case .retile: windowManager.retile()
        case .focusNextDisplay: windowManager.focusNextDisplay()
        case .moveWorkspaceToNextDisplay: windowManager.moveWorkspaceToNextDisplay()
        case .workspace(let index): windowManager.switchWorkspace(index)
        case .workspaceBackAndForth: windowManager.switchToPreviousWorkspace()
        case .moveToWorkspace(let index): windowManager.moveFocusedWindow(toWorkspace: index)
        case .resize(let width, let delta): windowManager.resizeFocused(width: width, by: delta)
        case .launch(let app): AppLauncher.open(app)
        case .shell(let command): shell(command)
        case .sendKey(let combo): KeyEmitter.post(combo)
        case .reload: reload()
        case .none: break
        case .navigate(let back): Navigation.perform(back: back)
        case .system(let action): action.perform()
        case .media(let key): key.post()
        case .click(let mods): Pointer.click(mods)
        case .scratchpad(let app): windowManager.toggleScratchpad(app: app)
        case .moveToScratchpad(let app): windowManager.moveToScratchpad(app: app)
        case .workspaceOverview: overview.toggle()
        }
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
