import AppKit
@preconcurrency import ApplicationServices
import HyperSpaceCore
import Synchronization

/// The tiling window manager: AeroSpace's model (`WMModel`), config and commands, driven by
/// Accessibility.
///
/// How it stays fast:
/// - **Event-driven state.** Windows are read once when they appear and then followed
///   through AX notifications; no command or notification re-reads every app's windows.
/// - **Diffs only.** `apply()` compares the layout with the frames already requested and
///   touches only windows that change, and per window only the attribute that changes.
/// - **Concurrent apps.** Each app has its own AX queue (`AXApp`), so frames are set in
///   parallel and a frozen app can't stall the others; superseded frames are skipped.
/// - **Off the input thread.** Hotkeys arrive as commands; the tap never waits for AX.
@MainActor
public final class WindowManager {
    public struct Handlers {
        public var reloadConfig: () -> Void
        public var enable: (Bool?) -> Void
        /// The binding mode changed: the tap must use that mode's hotkeys.
        public var modeChanged: (String) -> Void
        /// A media key (`volume up`...), sent like the keyboard's.
        public var mediaKey: (SystemAction) -> Void
        /// The focused workspace changed (for the menu bar).
        public var changed: () -> Void

        public init(reloadConfig: @escaping () -> Void, enable: @escaping (Bool?) -> Void,
                    modeChanged: @escaping (String) -> Void, mediaKey: @escaping (SystemAction) -> Void,
                    changed: @escaping () -> Void) {
            self.reloadConfig = reloadConfig
            self.enable = enable
            self.modeChanged = modeChanged
            self.mediaKey = mediaKey
            self.changed = changed
        }
    }

    private typealias FocusState = (window: WindowID?, workspace: String, monitor: UInt32)

    private let log = HyperSpace.logger("wm")
    private let handlers: Handlers
    private var model: WMModel?
    private var settings = WMSettings()
    private var observers: [any NSObjectProtocol] = []
    public private(set) var mode = "main"

    /// Every window seen, managed or not right now (minimized, hidden app).
    private var records: [WindowID: (app: AXApp, record: WindowRecord)] = [:]
    /// The frame each window has on screen as far as we know: set by us or read.
    private var frames: [WindowID: CGRect] = [:]
    /// The frame we last asked for: layouts are diffed against it, so a window that can't
    /// take a frame (minimum size) isn't asked again on every change.
    private var targets: [WindowID: CGRect] = [:]
    /// When we last set each window's frame: its own move notifications follow shortly.
    private var setAt: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows parked off-screen, with the frame to give back to floating ones.
    private var parked: [WindowID: CGRect] = [:]
    private var snapChecks: [WindowID: Task<Void, Never>] = [:]
    /// macOS native tabs (Finder, Safari, Terminal...): every tab is a window, but a tab
    /// group is one tile. Tab window -> the window that represents its group in the model.
    private var tabs: [WindowID: WindowID] = [:]
    /// Group window -> the tab currently shown, which is what focusing the group raises.
    private var shownTab: [WindowID: WindowID] = [:]
    private var tabChecks: [pid_t: Task<Void, Never>] = [:]

    /// Apps still reading their windows at startup (for `if.during-aerospace-startup`).
    private var startingApps = 0
    private var isStartingUp = true
    /// Callbacks don't retrigger themselves (AeroSpace's "recursion resistant").
    private var inCallback = false

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    public var focusedWorkspace: String? { model?.focusedWorkspace.name }

    // MARK: - Lifecycle

    public func start(_ settings: WMSettings) {
        self.settings = settings
        if let model {
            model.settings = settings
            if settings.modes[mode] == nil { setMode("main") }
            apply()
            return
        }
        // One timeout for every AX call: a frozen app answers nothing for 6 s by default.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXApp.timeout)
        model = WMModel(monitors: WindowManager.monitors(), settings: settings)
        isStartingUp = true
        observe()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        startingApps = apps.count
        for app in apps { watch(app) }
        if apps.isEmpty { isStartingUp = false }
        log.info("window manager started")
        handlers.changed()
    }

    /// Gives every window back: parked ones return on screen, nothing stays managed.
    public func stop() {
        guard model != nil else { return }
        for (id, frame) in parked {
            guard let (app, record) = records[id] else { continue }
            nonisolated(unsafe) let element = record.element
            app.queue.async { AX.setPosition(element, frame.origin) }
        }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        for app in AXApp.live.values { app.stop() }
        AXApp.live = [:]
        snapChecks.values.forEach { $0.cancel() }
        snapChecks = [:]
        records = [:]
        frames = [:]
        targets = [:]
        setAt = [:]
        parked = [:]
        tabs = [:]
        shownTab = [:]
        model = nil
        setMode("main")
        log.info("window manager stopped")
        handlers.changed()
    }

    // MARK: - Commands

    /// Runs commands from a hotkey or a callback, AeroSpace shell syntax included
    /// (`a; b`, `a && b`, `a || b`). Returns an error message for the user, if any.
    @discardableResult
    public func run(_ text: String, window: WindowID? = nil) -> String? {
        do {
            return execute(try WMScript(parsing: text), window: window).error
        } catch {
            return error.message
        }
    }

    /// Runs one command from `hsctl`, with its words as given (no shell parsing, so quoted
    /// arguments arrive intact).
    public func run(words: [String]) -> (ok: Bool, output: String, error: String?) {
        do {
            let result = execute(.command(try WMCommand(words: words)), window: nil)
            return (result.ok, result.output, result.error)
        } catch {
            return (false, "", error.message)
        }
    }

    private struct Result {
        var ok = true
        var output = ""
        var error: String?
    }

    private var focusState: FocusState? {
        model.map { ($0.focused, $0.focusedWorkspace.name, $0.focusedMonitor) }
    }

    private func execute(_ script: WMScript, window: WindowID?) -> Result {
        var result = Result()
        guard let before = focusState else {
            result.ok = false
            result.error = "the window manager is off (wm.toml is empty)"
            return result
        }
        result.ok = script.run { command in
            do throws(InvalidConfig) {
                let (ok, output) = try perform(command, window: window)
                if let output, !output.isEmpty { result.output += (result.output.isEmpty ? "" : "\n") + output }
                return ok
            } catch {
                result.error = error.message
                return false
            }
        }
        afterCommands(since: before)
        return result
    }

    /// One command. The model handles the tree, workspaces and monitors; the rest talks to
    /// other processes or the system and is done here.
    private func perform(_ command: WMCommand, window: WindowID?) throws(InvalidConfig) -> (Bool, String?) {
        guard let model else { return (false, nil) }
        switch command {
        case let .exec(script):
            exec(["/bin/bash", "-c", script], extra: window.map { ["AEROSPACE_WINDOW_ID": String($0)] } ?? [:])
        case .reloadConfig:
            handlers.reloadConfig()
        case let .enable(on, failIfNoop):
            if failIfNoop, on == true { return (false, nil) } // already on: we're running
            handlers.enable(on)
        case let .mode(name):
            guard settings.modes[name] != nil else { throw InvalidConfig(message: "there is no binding mode '\(name)'") }
            setMode(name)
        case let .triggerBinding(binding, mode):
            guard let script = settings.modes[mode]?[binding] else { throw InvalidConfig(message: "no binding '\(binding)' in mode '\(mode)'") }
            return (execute(script, window: window).ok, nil)
        case let .volume(volume):
            switch volume {
            case .up: handlers.mediaKey(.volumeUp)
            case .down: handlers.mediaKey(.volumeDown)
            case .muteToggle: handlers.mediaKey(.volumeMute)
            case .muteOn: exec(["/usr/bin/osascript", "-e", "set volume output muted true"])
            case .muteOff: exec(["/usr/bin/osascript", "-e", "set volume output muted false"])
            case let .set(level): exec(["/usr/bin/osascript", "-e", "set volume output volume \(level)"])
            }
        case let .moveMouse(position, failIfNoop):
            return (moveMouse(position) || !failIfNoop, nil)
        case let .list(query):
            return (true, list(query))
        case let .test(lhs, op, rhs, negate):
            let subject = window ?? model.focused
            let left = interpolate(lhs, window: subject), right = interpolate(rhs, window: subject)
            let result = switch op {
            case .equals: left == right
            case .matches: left.range(of: right, options: [.regularExpression, .caseInsensitive]) != nil
            }
            return (result != negate, nil)
        case let .result(value):
            return (value, nil)
        case let .echo(text):
            return (true, interpolate(text, window: window ?? model.focused))
        default:
            let (ok, effect) = try model.run(command, window: window)
            perform(effect)
            return (ok, nil)
        }
        return (true, nil)
    }

    private func perform(_ effect: WMEffect) {
        switch effect {
        case .none:
            break
        case let .close(ids, quitIfLastWindow):
            for id in ids {
                guard let (app, record) = records[id] else { continue }
                let appWindows = records.values.filter { $0.app.pid == app.pid }.count
                if quitIfLastWindow, appWindows == 1 {
                    NSRunningApplication(processIdentifier: app.pid)?.terminate()
                } else {
                    nonisolated(unsafe) let element = record.element
                    app.queue.async { AX.close(element) }
                }
            }
        case let .minimize(id):
            guard let (app, record) = records[id] else { return }
            nonisolated(unsafe) let element = record.element
            app.queue.async { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        case let .nativeFullscreen(id, on):
            guard let (app, record) = records[id] else { return }
            nonisolated(unsafe) let element = record.element
            app.queue.async {
                let wanted = on ?? !(AX.bool(element, "AXFullScreen") ?? false)
                AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, wanted as CFBoolean)
            }
        }
    }

    /// After commands: apply the layout, sync macOS focus, fire the focus callbacks.
    private func afterCommands(since before: FocusState) {
        guard let model else { return }
        apply()
        let workspace = model.focusedWorkspace.name
        if model.focused != before.window || workspace != before.workspace { focusNative() }
        focusChanged(since: before)
        if workspace != before.workspace { handlers.changed() }
    }

    private func focusChanged(since before: FocusState) {
        guard let model, !inCallback else { return }
        inCallback = true
        defer { inCallback = false }
        let workspace = model.focusedWorkspace.name
        if model.focused != before.window || workspace != before.workspace, let script = settings.onFocusChanged {
            _ = execute(script, window: model.focused)
        }
        if model.focusedMonitor != before.monitor, let script = settings.onFocusedMonitorChanged {
            _ = execute(script, window: model.focused)
        }
        if workspace != before.workspace, !settings.execOnWorkspaceChange.isEmpty {
            exec(settings.execOnWorkspaceChange, extra: ["AEROSPACE_FOCUSED_WORKSPACE": workspace, "AEROSPACE_PREV_WORKSPACE": before.workspace])
        }
    }

    private func setMode(_ name: String) {
        guard name != mode else { return }
        mode = name
        handlers.modeChanged(name)
        if !inCallback, let script = settings.onModeChanged {
            inCallback = true
            _ = execute(script, window: nil)
            inCallback = false
        }
    }

    /// HyperSpace's environment with Homebrew on the PATH, built once.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }()

    private func exec(_ argv: [String], extra: [String: String] = [:]) {
        guard let path = argv.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        process.environment = Self.environment.merging(extra) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { log.error("exec failed: \(error)") }
    }

    // MARK: - Queries

    /// `%{name}` variables of AeroSpace's `--format`, `test` and `echo`.
    private func variables(window: WindowID?, workspace name: String? = nil) -> [String: String] {
        guard let model else { return [:] }
        var values: [String: String] = [:]
        let workspace = name.map { model.workspace($0) } ?? window.flatMap { model.workspace(of: $0) } ?? model.focusedWorkspace
        values["workspace"] = workspace.name
        values["workspace-is-focused"] = String(workspace.name == model.focusedWorkspace.name)
        values["workspace-is-visible"] = String(model.isVisible(workspace.name))
        let monitorID = model.visible.first { $0.value == workspace.name }?.key ?? model.assignedMonitor(workspace.name)
        if let index = model.monitors.firstIndex(where: { $0.id == monitorID }) {
            values["monitor-id"] = String(index + 1)
            values["monitor-name"] = model.monitors[index].name
        }
        if let window, let (app, record) = records[window] {
            values["window-id"] = String(window)
            values["window-title"] = record.title
            values["window-is-fullscreen"] = String(workspace.fullscreen == window)
            values["window-layout"] = model.windows[window]?.floating == true ? "floating" : "tiling"
            values["app-name"] = NSRunningApplication(processIdentifier: app.pid)?.localizedName ?? ""
            values["app-bundle-id"] = app.bundleID ?? ""
            values["app-pid"] = String(app.pid)
        }
        return values
    }

    private func interpolate(_ text: String, window: WindowID?) -> String {
        guard text.contains("%{") else { return text }
        let values = variables(window: window)
        return text.replacing(/%\{([a-z-]+)\}/) { values[String($0.1)] ?? "" }
    }

    private func list(_ query: WMCommand.ListQuery) -> String {
        guard let model else { return "" }
        let filters = query.filters
        switch query.kind {
        case .workspaces:
            var names = model.workspaceNames
            if filters["--focused"] != nil { names = [model.focusedWorkspace.name] }
            if let monitors = filters["--monitor"] {
                let ids = Set(monitors.compactMap { monitorID($0) })
                names = names.filter { model.assignedMonitor($0).map(ids.contains) ?? false }
            }
            if let visible = filters["--visible"] { names = names.filter { model.isVisible($0) != (visible == ["no"]) } }
            if let empty = filters["--empty"] { names = names.filter { (model.workspaces[$0]?.isEmpty ?? true) != (empty == ["no"]) } }
            return format(names.map { variables(window: nil, workspace: $0) }, query, default: "%{workspace}")
        case .windows:
            var ids: [WindowID]
            if filters["--focused"] != nil {
                ids = model.focused.map { [$0] } ?? []
            } else if let names = filters["--workspace"] {
                ids = names.flatMap { name in
                    model.workspaces[name == "focused" ? model.focusedWorkspace.name : name]?.windows ?? []
                }
            } else if let monitors = filters["--monitor"] {
                let monitorIDs = Set(monitors.compactMap { monitorID($0) })
                ids = model.visible.filter { monitorIDs.contains($0.key) }.flatMap { model.workspace($0.value).windows }
            } else {
                ids = model.workspaceNames.flatMap { model.workspaces[$0]?.windows ?? [] }
            }
            if let pid = filters["--pid"]?.first.flatMap(Int32.init) { ids = ids.filter { records[$0]?.app.pid == pid } }
            if let bundle = filters["--app-bundle-id"]?.first { ids = ids.filter { records[$0]?.app.bundleID == bundle } }
            return format(ids.map { variables(window: $0) }, query, default: "%{window-id} | %{app-name} | %{window-title}")
        case .monitors:
            var monitors = model.monitors
            if filters["--focused"] != nil { monitors = monitors.filter { $0.id == model.focusedMonitor } }
            let rows = monitors.map { monitor in
                ["monitor-id": String((model.monitors.firstIndex { $0.id == monitor.id } ?? 0) + 1), "monitor-name": monitor.name]
            }
            return format(rows, query, default: "%{monitor-id} | %{monitor-name}")
        case .apps:
            let rows = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { app in
                ["app-pid": String(app.processIdentifier), "app-bundle-id": app.bundleIdentifier ?? "", "app-name": app.localizedName ?? ""]
            }
            return format(rows, query, default: "%{app-pid} | %{app-bundle-id} | %{app-name}")
        case .modes:
            let modes = filters["--current"] != nil ? [mode] : settings.modes.keys.sorted()
            return format(modes.map { ["mode-id": $0] }, query, default: "%{mode-id}")
        }
    }

    private func format(_ rows: [[String: String]], _ query: WMCommand.ListQuery, default fallback: String) -> String {
        if query.count { return String(rows.count) }
        if query.json {
            guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
            return String(decoding: data, as: UTF8.self)
        }
        let format = query.format ?? fallback
        return rows.map { row in format.replacing(/%\{([a-z-]+)\}/) { row[String($0.1)] ?? "" } }.joined(separator: "\n")
    }

    private func monitorID(_ pattern: String) -> UInt32? {
        guard let model else { return nil }
        if pattern == "focused" { return model.focusedMonitor }
        return model.monitors.first { WMMonitor.matches(pattern, $0, in: model.monitors) }?.id
    }

    // MARK: - Mouse

    /// Warps the pointer to the focused monitor or window ("lazy": only if it's elsewhere).
    private func moveMouse(_ position: WMCommand.MousePosition) -> Bool {
        guard let model else { return false }
        let mouse = CGEvent(source: nil)?.location ?? .zero
        let rect: CGRect? = switch position {
        case .monitorLazyCenter, .monitorForceCenter: model.monitors.first { $0.id == model.focusedMonitor }?.visible
        case .windowLazyCenter, .windowForceCenter: model.focused.flatMap { targets[$0] ?? frames[$0] }
        }
        guard let rect else { return false }
        let lazy = position == .monitorLazyCenter || position == .windowLazyCenter
        if lazy, rect.contains(mouse) { return false }
        CGWarpMouseCursorPosition(CGPoint(x: rect.midX, y: rect.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
        return true
    }

    /// `focus-follows-mouse`: the window under the pointer gets focus.
    public func mouseMoved(to point: CGPoint) {
        guard let model, settings.focusFollowsMouse, let before = focusState else { return }
        let layout = model.layout()
        let under = layout.floating.keys.first { frames[$0]?.contains(point) == true }
            ?? layout.tiled.first { $0.value.contains(point) }?.key
        guard let under, under != model.focused else { return }
        model.nativeFocus(under)
        focusNative()
        focusChanged(since: before)
    }

    // MARK: - System events

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { handler(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            if app.activationPolicy == .regular { self?.watch(app) }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in self?.forget(app: app.processIdentifier) }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] app in self?.syncFocus(app.processIdentifier) }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            guard let self else { return }
            if self.settings.automaticallyUnhideMacosHiddenApps {
                app.unhide()
            } else {
                self.setHidden(app.processIdentifier, true)
            }
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in self?.setHidden(app.processIdentifier, false) }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model?.setMonitors(WindowManager.monitors())
                self?.apply()
            }
        })
    }

    private func watch(_ running: NSRunningApplication) {
        let pid = running.processIdentifier
        guard AXApp.live[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else {
            appStarted()
            return
        }
        let app = AXApp(running) { [weak self] app, event in self?.handle(app, event) }
        AXApp.live[pid] = app
        let hidden = running.isHidden
        app.start { [weak self] records in
            guard let self, AXApp.live[pid] === app else { return }
            for record in records { self.add(record, of: app, managed: !hidden) }
            self.syncFocus(NSWorkspace.shared.frontmostApplication?.processIdentifier)
            self.apply()
            self.appStarted()
        }
    }

    private func appStarted() {
        guard isStartingUp else { return }
        startingApps -= 1
        if startingApps <= 0 { isStartingUp = false }
    }

    private func handle(_ app: AXApp, _ event: AXApp.Event) {
        switch event {
        case let .windowCreated(element):
            nonisolated(unsafe) let element = element
            // Managed windows of the same app: a new native tab lands exactly on one of them.
            nonisolated(unsafe) let groups: [(WindowID, AXUIElement, CGRect)] = records.compactMap { id, entry in
                guard entry.app.pid == app.pid, tabs[id] == nil, model?.windows[id] != nil,
                      let frame = targets[id] ?? frames[id] else { return nil }
                return (id, entry.record.element, frame)
            }
            app.queue.async { [weak self] in
                guard let record = app.record(element) else { return }
                let group = AXApp.tabGroup(of: element, among: groups)
                let diagnosis = group == nil && !groups.isEmpty
                    ? "now \(String(describing: AX.frame(element))), tab bar \(AXApp.hasTabBar(element)), same-app " + groups.map { "\($0.0) \($0.2) bar \(AXApp.hasTabBar($0.1))" }.joined(separator: "; ")
                    : ""
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.records[record.id] == nil else { return }
                        let message = "window \(record.id) of \(app.bundleID ?? "?"): frame \(String(describing: record.frame)), tab of \(group.map(String.init) ?? "none") \(diagnosis)"
                        self.log.info("\(message, privacy: .public)")
                        self.add(record, of: app, managed: true, tabOf: group)
                        self.apply()
                        self.scheduleTabCheck(app.pid)
                    }
                }
            }
        case let .windowDestroyed(id):
            forget(window: id)
            apply()
        case .focusChanged:
            syncFocus(app.pid)
            scheduleTabCheck(app.pid)
        case let .minimized(id, isMinimized):
            setManaged(id, !isMinimized)
            apply()
        case let .moved(id):
            moved(id)
        case let .titleChanged(id):
            guard let (app, record) = records[id] else { return }
            nonisolated(unsafe) let element = record.element
            app.queue.async { [weak self] in
                let title = AX.string(element, kAXTitleAttribute) ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.records[id]?.record.title = title } }
            }
        }
    }

    private func add(_ record: WindowRecord, of app: AXApp, managed: Bool, tabOf known: WindowID? = nil) {
        records[record.id] = (app, record)
        frames[record.id] = record.frame
        guard managed else { return }
        if let group = known ?? tabGroup(of: record, app) {
            tabs[record.id] = group
            shownTab[group] = record.id // a new tab is the one shown
            return
        }
        manage(record.id)
        windowDetected(record.id)
    }

    /// Tabs made in quick succession can slip past the check on creation. macOS shows only
    /// the selected tab of a group: any managed window of the app that is off screen (and
    /// not parked by us) while another window of the app sits on its frame is a background
    /// tab, and joins that window's group. One CGWindowList call, no AX.
    private func scheduleTabCheck(_ pid: pid_t) {
        tabChecks[pid]?.cancel()
        tabChecks[pid] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.tabChecks[pid] = nil
            self?.checkTabs(pid)
        }
    }

    private func checkTabs(_ pid: pid_t) {
        guard let model else { return }
        let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var windows: [WindowID: (bounds: CGRect, onscreen: Bool)] = [:]
        for info in all where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let id = info[kCGWindowNumber as String] as? WindowID, records[id] != nil,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            windows[id] = (bounds, info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        var changed = false
        for (id, window) in windows where !window.onscreen && model.windows[id] != nil && parked[id] == nil {
            guard let shown = windows.first(where: { $0.key != id && $0.value.onscreen && $0.value.bounds.isClose(to: window.bounds) })?.key
            else { continue }
            let group = tabs[shown] ?? shown
            guard group != id, model.windows[group] != nil else {
                shownTab[id] = shown // our group, showing another of its tabs
                continue
            }
            // A background tab that was tiled as a window: fold it (and its tabs) into the group.
            model.remove(id)
            for (tab, owner) in tabs where owner == id { tabs[tab] = group }
            tabs[id] = group
            shownTab[group] = shown == group ? nil : shown
            shownTab[id] = nil
            changed = true
        }
        if changed { apply() }
    }

    /// A window with a tab bar sitting exactly on a managed window of the same app is a
    /// new tab of that window's group, not a window to tile.
    private func tabGroup(of record: WindowRecord, _ app: AXApp) -> WindowID? {
        guard record.hasTabs, let frame = record.frame, let model else { return nil }
        return records.first { id, entry in
            id != record.id && entry.app.pid == app.pid && tabs[id] == nil && model.windows[id] != nil
                && (targets[id] ?? frames[id]).map { $0.isClose(to: frame) } == true
        }?.key
    }

    private func manage(_ id: WindowID) {
        guard let model, let record = records[id]?.record else { return }
        // At startup windows stay on the monitor they're on; later ones join the focused workspace.
        let monitor = isStartingUp ? record.frame.flatMap { frame in
            model.monitors.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
        } : nil
        model.add(WMWindowInfo(id: id, floating: record.floating), monitor: monitor)
    }

    /// `on-window-detected`: the first matching callback runs on the new window (and the
    /// next ones too while `check-further-callbacks` is set).
    private func windowDetected(_ id: WindowID) {
        guard let model, !settings.onWindowDetected.isEmpty else { return }
        let values = variables(window: id)
        let appName = values["app-name"] ?? "", title = values["window-title"] ?? ""
        for rule in settings.onWindowDetected {
            let matches: Bool
            switch rule.condition {
            case .always:
                matches = true
            case let .script(script):
                matches = execute(script, window: id).ok
            case let .legacy(appID, appNameRegex, titleRegex, workspace, duringStartup):
                matches = (appID.map { $0 == values["app-bundle-id"] } ?? true)
                    && (appNameRegex.map { appName.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true)
                    && (titleRegex.map { title.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true)
                    && (workspace.map { $0 == model.workspace(of: id)?.name } ?? true)
                    && (duringStartup.map { $0 == isStartingUp } ?? true)
            }
            guard matches else { continue }
            if let error = execute(rule.run, window: id).error { log.error("on-window-detected: \(error)") }
            if !rule.checkFurtherCallbacks { break }
        }
    }

    private func setManaged(_ id: WindowID, _ managed: Bool) {
        if managed { manage(id) } else { model?.remove(id) }
    }

    private func forget(window id: WindowID) {
        if let heir = tabs.first(where: { $0.value == id })?.key {
            // The group's window closed but other tabs remain: one of them stands in.
            model?.replace(id, with: heir)
            tabs[heir] = nil
            for (tab, group) in tabs where group == id { tabs[tab] = heir }
            shownTab[heir] = shownTab[id] == heir ? nil : shownTab[id]
            targets[heir] = targets[id]
        } else {
            model?.remove(id)
        }
        tabs[id] = nil
        shownTab[id] = nil
        for (group, tab) in shownTab where tab == id { shownTab[group] = nil }
        records[id] = nil
        frames[id] = nil
        targets[id] = nil
        setAt[id] = nil
        parked[id] = nil
        snapChecks.removeValue(forKey: id)?.cancel()
    }

    private func forget(app pid: pid_t) {
        AXApp.live.removeValue(forKey: pid)?.stop()
        for (id, entry) in records where entry.app.pid == pid { forget(window: id) }
        apply()
    }

    private func setHidden(_ pid: pid_t, _ hidden: Bool) {
        for (id, entry) in records where entry.app.pid == pid && tabs[id] == nil { setManaged(id, !hidden) }
        apply()
    }

    /// macOS focus moved: follow it (and show its workspace if it was hidden).
    private func syncFocus(_ pid: pid_t?) {
        guard let pid, let app = AXApp.live[pid] else { return }
        app.queue.async { [weak self] in
            // Some apps (Electron ones, mostly) don't always report a focused window: fall
            // back to their main window.
            let window: AXUIElement? = AX.value(app.element, kAXFocusedWindowAttribute) ?? AX.value(app.element, kAXMainWindowAttribute)
            let id = window.flatMap(AX.windowID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let model = self.model, let before = self.focusState else { return }
                    // A tab: its group is what the model knows; remember which tab is shown.
                    var id = id
                    if let tab = id, let group = self.tabs[tab] {
                        self.shownTab[group] = tab
                        id = group
                    } else if let window = id, self.shownTab[window] != nil {
                        self.shownTab[window] = nil
                    }
                    // Still nothing we manage: one of the app's managed windows will do.
                    let known = id.flatMap { model.windows[$0] != nil ? $0 : nil }
                        ?? self.records.filter { $0.value.app.pid == pid && model.windows[$0.key] != nil }.map(\.key).min()
                    if model.nativeFocus(known) { self.apply() }
                    self.focusChanged(since: before)
                    if model.focusedWorkspace.name != before.workspace { self.handlers.changed() }
                }
            }
        }
    }

    /// A window moved or resized. Floating: remember its frame. Tiled: if the user dragged
    /// it, put it back once the drag is over (our own moves match the known frame).
    private func moved(_ id: WindowID) {
        guard parked[id] == nil, let (app, record) = records[id] else { return }
        snapChecks.removeValue(forKey: id)?.cancel()
        snapChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            nonisolated(unsafe) let element = record.element
            app.queue.async {
                let frame = AX.frame(element)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let frame, self.parked[id] == nil else { return }
                        self.snapChecks[id] = nil
                        self.frames[id] = frame
                        // Right after our own change it's the app settling (e.g. a minimum size).
                        let ours = self.setAt[id].map { ContinuousClock.now - $0 < .seconds(1) } ?? false
                        // A tab that no longer sits on its group was dragged out: a window now.
                        if let group = self.tabs[id], !ours, let target = self.targets[group], !target.isClose(to: frame) {
                            self.tabs[id] = nil
                            self.manage(id)
                            self.apply()
                            return
                        }
                        guard !ours, let target = self.targets[id], !target.isClose(to: frame),
                              self.model?.windows[id]?.floating == false else { return }
                        self.targets[id] = nil // dragged by the user: put it back
                        self.apply()
                    }
                }
            }
        }
    }

    // MARK: - Applying the model

    /// Puts every window where the model says, touching only what changed.
    private func apply() {
        guard let model else { return }
        let layout = model.layout()
        var batches: [pid_t: (AXApp, [(AXUIElement, WindowID, CGRect, CGRect?)])] = [:]
        let now = ContinuousClock.now
        func set(_ id: WindowID, _ frame: CGRect) {
            guard let (app, record) = records[id] else { return }
            guard targets[id].map({ !$0.isClose(to: frame) }) ?? true else { return }
            let old = frames[id]
            frames[id] = frame
            targets[id] = frame
            setAt[id] = now
            batches[app.pid, default: (app, [])].1.append((record.element, id, frame, old))
        }
        // Show first, then hide: less flicker when switching workspaces.
        for (id, frame) in layout.tiled {
            parked[id] = nil
            set(id, frame)
        }
        for (id, _) in layout.floating {
            if let frame = parked.removeValue(forKey: id) { set(id, frame) }
        }
        for (id, monitorID) in layout.hidden where parked[id] == nil {
            guard let monitor = model.monitors.first(where: { $0.id == monitorID }), let frame = frames[id] else { continue }
            parked[id] = frame
            // Bottom right corner, one point inside so macOS doesn't pull the window back.
            set(id, CGRect(origin: CGPoint(x: monitor.visible.maxX - 1, y: monitor.visible.maxY - 1), size: frame.size))
        }
        // Tabs follow their group: same frame, parked with it.
        for (tab, group) in tabs {
            if let frame = parked[group] {
                if parked[tab] == nil, let target = targets[group] {
                    parked[tab] = frame
                    set(tab, target)
                }
            } else if let target = targets[group] {
                parked[tab] = nil
                set(tab, target)
            }
        }
        for (_, (app, changes)) in batches { app.setFrames(changes) }
    }

    /// Raises and focuses the model's focused window, as macOS would on a click.
    private func focusNative() {
        guard let focused = model?.focused, let (app, record) = records[shownTab[focused] ?? focused] else { return }
        nonisolated(unsafe) let element = record.element
        app.queue.async {
            // Raise first, so the window is on top by the time the app is active. The app is
            // made frontmost through AX: NSRunningApplication.activate() from a background
            // app can be refused by macOS 14+ cooperative activation.
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AX.raise(element)
            AXUIElementSetAttributeValue(app.element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Displays in AX coordinates: origin at the top left of the main display, y down.
    static func monitors() -> [WMMonitor] {
        guard let main = NSScreen.screens.first else { return [] }
        func ax(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return WMMonitor(id: id, name: screen.localizedName, isMain: screen == main,
                             frame: ax(screen.frame), visible: ax(screen.visibleFrame))
        }
    }
}

extension AXApp {
    /// Applies a batch of frames on the app's queue. A frame superseded by a newer one
    /// (fast repeated commands) is skipped instead of applied and then undone.
    func setFrames(_ changes: [(AXUIElement, WindowID, CGRect, CGRect?)]) {
        let generation = generations.withLock { generations in
            changes.map { change in
                generations[change.1, default: 0] += 1
                return generations[change.1]!
            }
        }
        nonisolated(unsafe) let changes = changes
        queue.async { [self] in
            // Accessibility clients like VoiceOver or Grammarly turn on "enhanced UI", which
            // animates every frame change: off while we move windows, like AeroSpace does.
            let enhanced = AX.bool(element, "AXEnhancedUserInterface") == true
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
            for (i, (window, id, frame, old)) in changes.enumerated() {
                guard generations.withLock({ $0[id] }) == generation[i] else { continue }
                AX.setFrame(window, frame, old: old)
            }
            if enhanced { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
    }
}

extension CGRect {
    /// Equal within a point: apps round frames their own way.
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}
