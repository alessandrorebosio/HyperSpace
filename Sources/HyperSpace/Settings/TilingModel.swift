import AppKit

/// State of the Tiling page: layout options, workspaces and window shortcuts.
/// Every change is written to config.json; the config watcher applies it.
final class TilingModel: ObservableObject {
    struct Workspace: Identifiable, Equatable {
        let id = UUID()
        var name: String
        /// Shortcut that shows the workspace.
        var switchKeys: String
        /// Shortcut that moves the focused window there.
        var moveKeys: String
    }

    /// A window-management action with an editable shortcut (stored in keyboard.bindings).
    struct Shortcut: Identifiable, Equatable {
        let title: String
        let action: String
        var keys: String
        var id: String { action }
    }

    enum Field: Equatable {
        case switchKeys(UUID)
        case moveKeys(UUID)
        case shortcut(String)
    }

    /// Shortcuts shown two to a row, like focus and move in the same direction: a caption over
    /// each column, one row per direction or dimension.
    struct PairedGroup {
        let title: String
        let columns: (String, String)
        let rows: [(title: String, actions: (String, String))]
    }

    static let pairedShortcuts: [PairedGroup] = [
        PairedGroup(title: "Focus & Move", columns: ("Focus", "Move window"), rows: [
            ("Left", ("focus left", "swap left")), ("Down", ("focus down", "swap down")),
            ("Up", ("focus up", "swap up")), ("Right", ("focus right", "swap right")),
        ]),
        PairedGroup(title: "Resize", columns: ("Smaller", "Larger"), rows: [
            ("Width", ("resize width -50", "resize width +50")),
            ("Height", ("resize height -50", "resize height +50")),
        ]),
    ]

    /// Shortcuts shown one to a row.
    static let singleShortcuts: [(group: String, items: [(title: String, action: String)])] = [
        ("Displays", [
            ("Focus other display", "focus-display"),
            ("Move workspace to other display", "move-workspace-to-display"),
        ]),
        ("More", [
            ("Previous workspace", "workspace back-and-forth"),
            ("Toggle floating", "float"),
            ("Stack windows as an accordion", "accordion"),
            ("Move window to or from the scratchpad", "move-to-scratchpad"),
        ]),
    ]

    /// Every window-management action with an editable shortcut, in page order: the single
    /// source the Shortcuts page and the saved bindings derive from.
    static let shortcutActions: [(title: String, action: String)] = {
        var all: [(title: String, action: String)] = []
        for group in pairedShortcuts {
            for row in group.rows {
                all.append((title: "\(group.columns.0) · \(row.title)", action: row.actions.0))
                all.append((title: "\(group.columns.1) · \(row.title)", action: row.actions.1))
            }
        }
        for group in singleShortcuts { all += group.items }
        return all
    }()

    /// Where every option starts: the defaults of the config itself.
    private static let defaults = TilingConfig()
    /// The slider ranges (the config accepts the same ones).
    static let spacingRange = Int(TilingConfig.spacingRange.lowerBound)...Int(TilingConfig.spacingRange.upperBound)
    static let accordionRange = 0...120

    @Published private(set) var enabled = TilingModel.defaults.enabled
    @Published private(set) var layout = TilingModel.defaults.layout
    @Published private(set) var gap = Int(TilingModel.defaults.gap)
    @Published private(set) var padding = Int(TilingModel.defaults.padding)
    @Published private(set) var mouseFollowsFocus = TilingModel.defaults.mouseFollowsFocus
    @Published private(set) var accordionPadding = Int(TilingModel.defaults.accordionPadding)
    @Published var workspaces: [Workspace] = []
    /// Bundle identifiers of apps whose windows are never tiled.
    @Published private(set) var floating: [String] = []
    @Published private(set) var floatingWindows: [FloatingWindowRule] = []
    /// The rule being written: app (nil for any) and title text.
    @Published var newFloatingApp: String?
    @Published var newFloatingTitle = ""
    /// Apps whose windows open in a given workspace (by name).
    @Published private(set) var assignments: [Assignment] = []

    struct Assignment: Identifiable, Equatable {
        let id = UUID()
        var app: String
        var workspace: String
    }
    @Published private(set) var shortcuts: [Shortcut] = []
    /// An app with its own scratchpad shortcuts: show/hide ("scratchpad <bundle id>") and
    /// into the tiling and back ("move-to-scratchpad <bundle id>").
    struct ScratchpadApp: Identifiable, Equatable {
        let bundleID: String
        var toggleKeys = ""
        var tileKeys = ""
        var id: String { bundleID }
        var toggleAction: String { TilingModel.togglePrefix + bundleID }
        var tileAction: String { TilingModel.tilePrefix + bundleID }
    }
    @Published private(set) var scratchpadApps: [ScratchpadApp] = []
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?

    private let eventTap: EventTap
    private let monitor = LocalEventMonitor()
    private var pendingSave: DispatchWorkItem?

    /// Posted (with the new value) when tiling is turned on or off from the menu bar.
    static let enabledDidChange = Notification.Name("HyperSpace.tilingEnabledDidChange")
    private var enabledObserver: NSObjectProtocol?

    init(eventTap: EventTap) {
        self.eventTap = eventTap
        load()
        enabledObserver = NotificationCenter.default.addObserver(forName: Self.enabledDidChange, object: nil, queue: .main) { [weak self] note in
            if let on = note.object as? Bool { self?.enabled = on }
        }
    }

    deinit {
        if let enabledObserver { NotificationCenter.default.removeObserver(enabledObserver) }
        stopCapture()
        // A rename typed just before closing the window is still saved.
        if pendingSave != nil { save() }
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) { enabled = on; save() }
    func setLayout(_ kind: LayoutKind) { layout = kind; save() }
    /// `commit` false while a slider is being dragged: the value shows at once, the config is
    /// written (and the windows retiled) once, when the slider is released.
    func setGap(_ value: Int, commit: Bool = true) { gap = value.clamped(to: Self.spacingRange); if commit { save() } }
    func setPadding(_ value: Int, commit: Bool = true) { padding = value.clamped(to: Self.spacingRange); if commit { save() } }
    func setMouseFollowsFocus(_ on: Bool) { mouseFollowsFocus = on; save() }
    func setAccordionPadding(_ value: Int, commit: Bool = true) {
        accordionPadding = value.clamped(to: Self.accordionRange)
        if commit { save() }
    }

    func addWorkspace() {
        workspaces.append(Workspace(name: "\(workspaces.count + 1)", switchKeys: "", moveKeys: ""))
        save()
    }

    func removeWorkspace(_ id: UUID) {
        stopCapture()
        workspaces.removeAll { $0.id == id }
        save()
    }

    func addFloating(_ bundleID: String) {
        guard !floating.contains(bundleID) else { return }
        floating.append(bundleID)
        save()
    }

    func removeFloating(_ bundleID: String) {
        floating.removeAll { $0 == bundleID }
        save()
    }

    func addFloatingWindow() {
        let title = newFloatingTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let rule = FloatingWindowRule(app: newFloatingApp, title: title)
        guard !floatingWindows.contains(rule) else { return }
        floatingWindows.append(rule)
        newFloatingTitle = ""
        save()
    }

    func removeFloatingWindow(_ rule: FloatingWindowRule) {
        floatingWindows.removeAll { $0 == rule }
        save()
    }

    /// The rule being written needs an app, a title, or both.
    var canAddFloatingRule: Bool {
        newFloatingApp != nil || !newFloatingTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Adds the rule being written: an app without a title floats all its windows.
    func addFloatingRule() {
        guard newFloatingTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return addFloatingWindow() }
        guard let app = newFloatingApp else { return }
        addFloating(app)
        newFloatingApp = nil
    }

    var assignmentCandidates: [(name: String, bundleID: String)] {
        Self.runningApps.filter { app in !assignments.contains { $0.app == app.bundleID } }
    }

    /// The regular apps running, by name. The pages ask on every redraw (a keystroke in a
    /// text field), so the list is kept until an app launches or quits.
    static var runningApps: [(name: String, bundleID: String)] {
        if let cached = cachedApps { return cached }
        watchRunningApps()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        cachedApps = apps
        return apps
    }

    private static var cachedApps: [(name: String, bundleID: String)]?
    private static var appObservers: [NSObjectProtocol] = []

    private static func watchRunningApps() {
        guard appObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                TilingModel.cachedApps = nil
            })
        }
    }

    var scratchpadCandidates: [(name: String, bundleID: String)] {
        Self.runningApps.filter { app in !scratchpadApps.contains { $0.bundleID == app.bundleID } }
    }

    fileprivate static let togglePrefix = "scratchpad "
    fileprivate static let tilePrefix = "move-to-scratchpad "

    /// Adds an app and records its show/hide shortcut right away.
    func addScratchpadApp(_ bundleID: String) {
        if !scratchpadApps.contains(where: { $0.bundleID == bundleID }) {
            scratchpadApps.append(ScratchpadApp(bundleID: bundleID))
        }
        startCapture(.shortcut(ScratchpadApp(bundleID: bundleID).toggleAction))
    }

    /// Asks for any installed app, running or not; its bundle identifier.
    private func chooseApp(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    func chooseAppForScratchpad() {
        if let bundleID = chooseApp(prompt: "Add") { addScratchpadApp(bundleID) }
    }

    func removeScratchpadApp(_ bundleID: String) {
        stopCapture()
        scratchpadApps.removeAll { $0.bundleID == bundleID }
        save()
    }

    func addAssignment(_ bundleID: String) {
        guard !assignments.contains(where: { $0.app == bundleID }), let first = workspaces.first else { return }
        assignments.append(Assignment(app: bundleID, workspace: first.name))
        save()
    }

    func chooseAppForAssignment() {
        if let bundleID = chooseApp(prompt: "Assign") { addAssignment(bundleID) }
    }

    func setAssignment(_ id: UUID, workspace: String) {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else { return }
        assignments[index].workspace = workspace
        save()
    }

    func removeAssignment(_ id: UUID) {
        assignments.removeAll { $0.id == id }
        save()
    }

    /// Names and icons by bundle id: rows ask on every redraw, LaunchServices is slow.
    private static var appInfo: [String: (name: String, icon: NSImage?)] = [:]

    private static func info(_ bundleID: String) -> (name: String, icon: NSImage?) {
        if let info = appInfo[bundleID] { return info }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let info = (name: url.map { Self.appDisplayName(at: $0) } ?? bundleID,
                    icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        appInfo[bundleID] = info
        return info
    }

    /// The name Finder shows for the app, less a trailing ".app" (shown when extensions are on).
    private static func appDisplayName(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func appName(_ bundleID: String) -> String { info(bundleID).name }

    static func appIcon(_ bundleID: String) -> NSImage? { info(bundleID).icon }

    /// Typing a name saves shortly after the last keystroke.
    func rename(_ id: UUID, to name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        // App rules follow their workspace's new name.
        let old = workspaces[index].name
        for i in assignments.indices where assignments[i].workspace == old { assignments[i].workspace = name }
        workspaces[index].name = name
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Shortcuts used more than once, which only the last one would get.
    func isDuplicate(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }
        let all = workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } + shortcuts.map(\.keys)
            + scratchpadApps.flatMap { [$0.toggleKeys, $0.tileKeys] }
        return all.filter { $0 == keys }.count > 1
    }

    // MARK: - Capture

    /// Records the next shortcut pressed. Key bindings are paused so an existing
    /// shortcut reaches the window, but key remaps stay on, so caps lock → ⌃⌥⇧ counts.
    /// Escape alone cancels, Delete alone clears the shortcut.
    func startCapture(_ field: Field) {
        stopCapture()
        capturing = field
        eventTap.setKeyBindingsSuspended(true)
        monitor.start(.keyDown) { [weak self] event in
            guard let self, let name = KeyCodes.name(forKeyCode: event.keyCode) else { return true }
            let mods = Modifiers(event.modifierFlags)
            switch (name, mods.isEmpty) {
            case ("escape", true): stopCapture()
            case ("delete", true): finishCapture("")
            default: finishCapture(mods.text(key: name))
            }
            return true
        }
    }

    func stopCapture() {
        monitor.stop()
        guard capturing != nil else { return }
        capturing = nil
        eventTap.setKeyBindingsSuspended(false)
    }

    private func finishCapture(_ keys: String) {
        switch capturing {
        case .switchKeys(let id):
            if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].switchKeys = keys }
        case .moveKeys(let id):
            if let index = workspaces.firstIndex(where: { $0.id == id }) { workspaces[index].moveKeys = keys }
        case .shortcut(let action):
            if let index = shortcuts.firstIndex(where: { $0.action == action }) { shortcuts[index].keys = keys }
            if let index = scratchpadApps.firstIndex(where: { $0.toggleAction == action }) { scratchpadApps[index].toggleKeys = keys }
            if let index = scratchpadApps.firstIndex(where: { $0.tileAction == action }) { scratchpadApps[index].tileKeys = keys }
        case nil:
            break
        }
        stopCapture()
        save()
    }

    // MARK: - Persistence

    private func load() {
        let root = ConfigWriter.read()
        let tiling = root["tiling"] as? [String: Any] ?? [:]
        let defaults = Self.defaults
        enabled = tiling["enabled"] as? Bool ?? defaults.enabled
        layout = (tiling["layout"] as? String).flatMap { LayoutKind(rawValue: $0.lowercased()) } ?? defaults.layout
        // The config clamps these too: what a hand-edited file holds shows as it will apply.
        gap = ((tiling["gap"] as? NSNumber)?.intValue ?? Int(defaults.gap)).clamped(to: Self.spacingRange)
        padding = ((tiling["padding"] as? NSNumber)?.intValue ?? Int(defaults.padding)).clamped(to: Self.spacingRange)
        mouseFollowsFocus = tiling["mouseFollowsFocus"] as? Bool ?? defaults.mouseFollowsFocus
        accordionPadding = (tiling["accordionPadding"] as? NSNumber)?.intValue ?? Int(defaults.accordionPadding)
        floating = tiling["floating"] as? [String] ?? []
        floatingWindows = (tiling["floatingWindows"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let title = entry["title"] as? String, !title.isEmpty else { return nil }
            return FloatingWindowRule(app: (entry["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }, title: title)
        }
        assignments = (tiling["assign"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let app = entry["app"] as? String, let workspace = entry["workspace"] as? String else { return nil }
            return Assignment(app: app, workspace: workspace)
        }
        workspaces = (tiling["workspaces"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
            Workspace(name: entry["name"] as? String ?? "\(index + 1)",
                      switchKeys: entry["switch"] as? String ?? "",
                      moveKeys: entry["move"] as? String ?? "")
        }

        let bindings = (root["keyboard"] as? [String: Any])?["bindings"] as? [[String: Any]] ?? []
        shortcuts = Self.shortcutActions.map { item in
            let keys = bindings.last { ($0["action"] as? String) == item.action }?["keys"] as? String
            return Shortcut(title: item.title, action: item.action, keys: keys ?? "")
        }
        var pads: [ScratchpadApp] = []
        for binding in bindings {
            guard let action = binding["action"] as? String, let keys = binding["keys"] as? String else { continue }
            let toggle = action.hasPrefix(Self.togglePrefix)
            guard toggle || action.hasPrefix(Self.tilePrefix) else { continue }
            let bundleID = String(action.dropFirst((toggle ? Self.togglePrefix : Self.tilePrefix).count))
            if !pads.contains(where: { $0.bundleID == bundleID }) { pads.append(ScratchpadApp(bundleID: bundleID)) }
            let index = pads.firstIndex { $0.bundleID == bundleID }!
            if toggle { pads[index].toggleKeys = keys } else { pads[index].tileKeys = keys }
        }
        scratchpadApps = pads
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        saveError = ConfigWriter.save { root in
            var tiling = root["tiling"] as? [String: Any] ?? [:]
            tiling["enabled"] = enabled
            tiling["layout"] = layout.rawValue
            tiling["gap"] = gap
            tiling["padding"] = padding
            tiling["mouseFollowsFocus"] = mouseFollowsFocus
            tiling["accordionPadding"] = accordionPadding == Int(Self.defaults.accordionPadding) ? nil : accordionPadding
            tiling["floating"] = floating
            tiling["floatingWindows"] = floatingWindows.isEmpty ? nil : floatingWindows.map { rule -> [String: Any] in
                var entry: [String: Any] = ["title": rule.title]
                if let app = rule.app { entry["app"] = app }
                return entry
            }
            // Rules pointing at a workspace that no longer exists are dropped.
            let names = Set(workspaces.map(\.name))
            let rules = assignments.filter { names.contains($0.workspace) }
            tiling["assign"] = rules.isEmpty ? nil : rules.map { ["app": $0.app, "workspace": $0.workspace] }
            tiling["workspaces"] = workspaces.isEmpty ? nil : workspaces.map { workspace -> [String: Any] in
                var entry: [String: Any] = ["name": workspace.name]
                if !workspace.switchKeys.isEmpty { entry["switch"] = workspace.switchKeys }
                if !workspace.moveKeys.isEmpty { entry["move"] = workspace.moveKeys }
                return entry
            }
            root["tiling"] = tiling

            // Each window shortcut edits the last binding of its action (the one the page shows)
            // in place; other bindings, even more for the same action, stay where they are.
            var keyboard = root["keyboard"] as? [String: Any] ?? [:]
            var bindings = keyboard["bindings"] as? [[String: Any]] ?? []
            func actionText(_ binding: [String: Any]) -> String { binding["action"] as? String ?? "" }
            // An app taken off the scratchpad list loses all its bindings.
            let padActions = Set(scratchpadApps.flatMap { [$0.toggleAction, $0.tileAction] })
            bindings.removeAll {
                let action = actionText($0)
                return (action.hasPrefix(Self.togglePrefix) || action.hasPrefix(Self.tilePrefix)) && !padActions.contains(action)
            }
            var desired: [(action: String, keys: String)] = shortcuts.map { (action: $0.action, keys: $0.keys) }
            for pad in scratchpadApps {
                desired.append((action: pad.toggleAction, keys: pad.toggleKeys))
                desired.append((action: pad.tileAction, keys: pad.tileKeys))
            }
            var cleared = Set<Int>()
            var added: [[String: Any]] = []
            for entry in desired {
                if let index = bindings.lastIndex(where: { actionText($0) == entry.action }) {
                    if entry.keys.isEmpty {
                        cleared.insert(index)
                    } else if bindings[index]["keys"] as? String != entry.keys {
                        bindings[index]["keys"] = entry.keys
                    }
                } else if !entry.keys.isEmpty {
                    added.append(["keys": entry.keys, "action": entry.action])
                }
            }
            bindings = bindings.enumerated().filter { !cleared.contains($0.offset) }.map(\.element) + added
            keyboard["bindings"] = bindings
            root["keyboard"] = keyboard
        }
    }
}
