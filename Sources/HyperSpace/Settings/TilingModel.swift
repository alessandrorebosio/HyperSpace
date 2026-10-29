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

    static let shortcutActions: [(group: String, items: [(title: String, action: String)])] = [
        ("Focus", [
            ("Focus left", "focus left"), ("Focus down", "focus down"),
            ("Focus up", "focus up"), ("Focus right", "focus right"),
            ("Focus other display", "focus-display"),
        ]),
        ("Move", [
            ("Move window left", "swap left"), ("Move window down", "swap down"),
            ("Move window up", "swap up"), ("Move window right", "swap right"),
            ("Move workspace to other display", "move-workspace-to-display"),
            ("Move window to other display", "display next"),
        ]),
        ("Resize", [
            ("Wider", "resize width +50"), ("Narrower", "resize width -50"),
            ("Taller", "resize height +50"), ("Shorter", "resize height -50"),
        ]),
        ("Workspaces & layout", [
            ("Previous workspace", "workspace back-and-forth"),
            ("Next layout", "layout next"),
            ("Toggle floating", "float"),
        ]),
        ("Scratchpad", [
            ("Show or hide the scratchpad", "scratchpad"),
            ("Move window to or from the scratchpad", "move-to-scratchpad"),
        ]),
    ]

    @Published private(set) var enabled = true
    @Published private(set) var layout = LayoutKind.columns
    @Published private(set) var gap = 8
    @Published private(set) var padding = 8
    @Published private(set) var mouseFollowsFocus = true
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
    /// Apps with their own scratchpad shortcut ("scratchpad <bundle id>" bindings).
    @Published private(set) var scratchpadApps: [Shortcut] = []
    @Published private(set) var capturing: Field?
    @Published private(set) var saveError: String?

    private let eventTap: EventTap
    private let monitor = LocalEventMonitor()
    private var pendingSave: DispatchWorkItem?

    init(eventTap: EventTap) {
        self.eventTap = eventTap
        load()
    }

    deinit {
        stopCapture()
        // A rename typed just before closing the window is still saved.
        if pendingSave != nil { save() }
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) { enabled = on; save() }
    func setLayout(_ kind: LayoutKind) { layout = kind; save() }
    func setGap(_ value: Int) { gap = max(0, min(64, value)); save() }
    func setPadding(_ value: Int) { padding = max(0, min(64, value)); save() }
    func setMouseFollowsFocus(_ on: Bool) { mouseFollowsFocus = on; save() }

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

    /// Running apps that could be made floating, by name.
    var floatingCandidates: [(name: String, bundleID: String)] {
        Self.runningApps.filter { !floating.contains($0.bundleID) }
    }

    var assignmentCandidates: [(name: String, bundleID: String)] {
        Self.runningApps.filter { app in !assignments.contains { $0.app == app.bundleID } }
    }

    static var runningApps: [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { (app.localizedName ?? $0, $0) } }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var scratchpadCandidates: [(name: String, bundleID: String)] {
        Self.runningApps.filter { app in !scratchpadApps.contains { $0.action == Self.scratchpadAction(app.bundleID) } }
    }

    static func scratchpadAction(_ bundleID: String) -> String { "scratchpad \(bundleID)" }

    static func scratchpadApp(_ shortcut: Shortcut) -> String {
        String(shortcut.action.dropFirst("scratchpad ".count))
    }

    /// Adds an app and records its shortcut right away.
    func addScratchpadApp(_ bundleID: String) {
        let action = Self.scratchpadAction(bundleID)
        if !scratchpadApps.contains(where: { $0.action == action }) {
            scratchpadApps.append(Shortcut(title: Self.appName(bundleID), action: action, keys: ""))
        }
        startCapture(.shortcut(action))
    }

    func chooseAppForScratchpad() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addScratchpadApp(bundleID)
    }

    func removeScratchpadApp(_ action: String) {
        if capturing == .shortcut(action) { stopCapture() }
        scratchpadApps.removeAll { $0.action == action }
        save()
    }

    func addAssignment(_ bundleID: String) {
        guard !assignments.contains(where: { $0.app == bundleID }), let first = workspaces.first else { return }
        assignments.append(Assignment(app: bundleID, workspace: first.name))
        save()
    }

    /// Picks any installed app, running or not.
    func chooseAppForAssignment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Assign"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addAssignment(bundleID)
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

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

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
        let all = workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } + (shortcuts + scratchpadApps).map(\.keys)
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
            if let index = scratchpadApps.firstIndex(where: { $0.action == action }) { scratchpadApps[index].keys = keys }
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
        enabled = tiling["enabled"] as? Bool ?? true
        layout = (tiling["layout"] as? String).flatMap { LayoutKind(rawValue: $0.lowercased()) } ?? .columns
        gap = (tiling["gap"] as? NSNumber)?.intValue ?? 8
        padding = (tiling["padding"] as? NSNumber)?.intValue ?? 8
        mouseFollowsFocus = tiling["mouseFollowsFocus"] as? Bool ?? true
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
        shortcuts = Self.shortcutActions.flatMap(\.items).map { item in
            let keys = bindings.last { ($0["action"] as? String) == item.action }?["keys"] as? String
            return Shortcut(title: item.title, action: item.action, keys: keys ?? "")
        }
        scratchpadApps = bindings.compactMap { binding in
            guard let action = binding["action"] as? String, action.hasPrefix("scratchpad "),
                  let keys = binding["keys"] as? String else { return nil }
            return Shortcut(title: Self.appName(String(action.dropFirst("scratchpad ".count))), action: action, keys: keys)
        }
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

            // Window shortcuts replace their own bindings; other bindings are kept as they are.
            var keyboard = root["keyboard"] as? [String: Any] ?? [:]
            let managed = Set(shortcuts.map(\.action))
            var bindings = (keyboard["bindings"] as? [[String: Any]] ?? []).filter {
                let action = $0["action"] as? String ?? ""
                return !managed.contains(action) && !action.hasPrefix("scratchpad ")
            }
            bindings += (shortcuts + scratchpadApps).filter { !$0.keys.isEmpty }.map { ["keys": $0.keys, "action": $0.action] }
            keyboard["bindings"] = bindings
            root["keyboard"] = keyboard
        }
    }
}
