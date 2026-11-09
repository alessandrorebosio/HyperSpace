import AppKit
import Combine

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
        /// The display it is pinned to ("" for automatic): see `ScreenInfo.pinned`.
        var display = ""
    }

    /// A choice in a workspace's display menu: the value written to the config and its label.
    struct DisplayOption: Hashable {
        let value: String
        let label: String
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
        /// Caption over the row titles.
        let leading: String
        let columns: (String, String)
        let rows: [(title: String, actions: (String, String))]
    }

    static let pairedShortcuts: [PairedGroup] = [
        PairedGroup(title: "Focus & Move", leading: "Direction", columns: ("Focus", "Move window"), rows: [
            ("Left", ("focus left", "swap left")), ("Down", ("focus down", "swap down")),
            ("Up", ("focus up", "swap up")), ("Right", ("focus right", "swap right")),
        ]),
        PairedGroup(title: "Resize", leading: "Dimension", columns: ("Smaller", "Larger"), rows: [
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
            ("Show workspaces while held", "workspace-overview"),
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
    private typealias Defaults = TilingConfig
    /// The slider ranges (the config accepts the same ones).
    static let spacingRange = Int(TilingConfig.spacingRange.lowerBound)...Int(TilingConfig.spacingRange.upperBound)
    static let accordionRange = Int(TilingConfig.accordionPaddingRange.lowerBound)...Int(TilingConfig.accordionPaddingRange.upperBound)

    @Published private(set) var enabled = Defaults.defaultEnabled
    @Published private(set) var layout = Defaults.defaultLayout
    @Published private(set) var gap = Int(Defaults.defaultGap)
    @Published private(set) var padding = Int(Defaults.defaultPadding)
    @Published private(set) var mouseFollowsFocus = Defaults.defaultMouseFollowsFocus
    @Published private(set) var accordionPadding = Int(Defaults.defaultAccordionPadding)
    @Published var workspaces: [Workspace] = [] { didSet { duplicateCache = nil } }
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
    @Published private(set) var shortcuts: [Shortcut] = [] { didSet { duplicateCache = nil } }
    /// The shortcuts used more than once, kept until the workspaces, shortcuts or scratchpad apps change.
    private var duplicateCache: Set<String>?
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
    @Published private(set) var scratchpadApps: [ScratchpadApp] = [] { didSet { duplicateCache = nil } }
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
    /// The slider setters only update the shown value; `commitSpacing` writes them.
    func setGap(_ value: Int) { gap = value.clamped(to: Self.spacingRange) }
    func setPadding(_ value: Int) { padding = value.clamped(to: Self.spacingRange) }
    func setAccordionPadding(_ value: Int) { accordionPadding = value.clamped(to: Self.accordionRange) }
    /// Writes the current slider values (the config reload retiles once, on release).
    func commitSpacing() { save() }
    func setMouseFollowsFocus(_ on: Bool) { mouseFollowsFocus = on; save() }

    func addWorkspace() {
        workspaces.append(Workspace(name: TilingConfig.workspaceName(nil, at: workspaces.count), switchKeys: "", moveKeys: ""))
        save()
    }

    func setDisplay(_ display: String, for id: UUID) {
        if workspaces.update(id: id, { $0.display = display }) { save() }
    }

    /// The display choices for a workspace: automatic, the main display, every connected
    /// display by name, and the workspace's own pin even when that display is not connected.
    /// `screens` is `ScreenInfo.current()`, read once for all the rows.
    func displayOptions(for workspace: Workspace, screens: [ScreenInfo]) -> [DisplayOption] {
        var options = [DisplayOption(value: "", label: "Any display"), DisplayOption(value: "main", label: "Main display")]
        for (index, screen) in screens.enumerated() {
            let name = screen.name.isEmpty ? "Display \(index + 1)" : screen.name
            options.append(DisplayOption(value: screen.pinValue(among: screens), label: name))
        }
        if !workspace.display.isEmpty, !options.contains(where: { $0.value == workspace.display }) {
            let connected = ScreenInfo.pinned(workspace.display, among: screens)
            let label = connected.map { $0.name.isEmpty ? workspace.display : $0.name }
                ?? "\(workspace.display) (not connected)"
            options.append(DisplayOption(value: workspace.display, label: label))
        }
        return options
    }

    func removeWorkspace(_ id: UUID) {
        stopCapture()
        workspaces.removeAll { $0.id == id }
        save()
    }

    private func addFloating(_ bundleID: String) {
        guard !floating.contains(bundleID) else { return }
        floating.append(bundleID)
        save()
    }

    func removeFloating(_ bundleID: String) {
        floating.removeAll { $0 == bundleID }
        save()
    }

    private func addFloatingWindow() {
        guard let rule = TilingConfig.floatingRule(app: newFloatingApp, title: newFloatingTitle.trimmingCharacters(in: .whitespaces)),
              !floatingWindows.contains(rule) else { return }
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
        AppLauncher.runningApps.filter { app in !assignments.contains { $0.app == app.bundleID } }
    }

    var scratchpadCandidates: [(name: String, bundleID: String)] {
        AppLauncher.runningApps.filter { app in !scratchpadApps.contains { $0.bundleID == app.bundleID } }
    }

    static let togglePrefix = "scratchpad "
    static let tilePrefix = "move-to-scratchpad "

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
        if assignments.update(id: id, { $0.workspace = workspace }) { save() }
    }

    func removeAssignment(_ id: UUID) {
        assignments.removeAll { $0.id == id }
        save()
    }

    /// Typing a name saves shortly after the last keystroke.
    func rename(_ id: UUID, to name: String) {
        var old: String?
        guard workspaces.update(id: id, { old = $0.name; $0.name = name }) else { return }
        // App rules follow their workspace's new name.
        for i in assignments.indices where assignments[i].workspace == old { assignments[i].workspace = name }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Shortcuts used more than once, which only the last one would get.
    func isDuplicate(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }
        if duplicateCache == nil {
            var counts: [String: Int] = [:]
            let all = workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } + shortcuts.map(\.keys)
                + scratchpadApps.flatMap { [$0.toggleKeys, $0.tileKeys] }
            for keys in all { counts[keys, default: 0] += 1 }
            duplicateCache = Set(counts.filter { $0.value > 1 }.keys)
        }
        return duplicateCache?.contains(keys) ?? false
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
            workspaces.update(id: id) { $0.switchKeys = keys }
        case .moveKeys(let id):
            workspaces.update(id: id) { $0.moveKeys = keys }
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
        enabled = tiling["enabled"] as? Bool ?? Defaults.defaultEnabled
        layout = (tiling["layout"] as? String).flatMap { LayoutKind(configText: $0) } ?? Defaults.defaultLayout
        // The config clamps these too: what a hand-edited file holds shows as it will apply.
        gap = ((tiling["gap"] as? NSNumber)?.intValue ?? Int(Defaults.defaultGap)).clamped(to: Self.spacingRange)
        padding = ((tiling["padding"] as? NSNumber)?.intValue ?? Int(Defaults.defaultPadding)).clamped(to: Self.spacingRange)
        mouseFollowsFocus = tiling["mouseFollowsFocus"] as? Bool ?? Defaults.defaultMouseFollowsFocus
        accordionPadding = ((tiling["accordionPadding"] as? NSNumber)?.intValue ?? Int(Defaults.defaultAccordionPadding)).clamped(to: Self.accordionRange)
        floating = tiling["floating"] as? [String] ?? []
        // The rules as the config reads them; one listed twice shows once (the list is keyed by rule).
        var rules: [FloatingWindowRule] = []
        for entry in tiling["floatingWindows"] as? [[String: Any]] ?? [] {
            guard let title = entry["title"] as? String,
                  let rule = TilingConfig.floatingRule(app: entry["app"] as? String, title: title),
                  !rules.contains(rule) else { continue }
            rules.append(rule)
        }
        floatingWindows = rules
        assignments = (tiling["assign"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let app = entry["app"] as? String, let workspace = entry["workspace"] as? String else { return nil }
            return Assignment(app: app, workspace: workspace)
        }
        workspaces = (tiling["workspaces"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
            Workspace(name: TilingConfig.workspaceName(entry["name"] as? String, at: index),
                      switchKeys: entry["switch"] as? String ?? "",
                      moveKeys: entry["move"] as? String ?? "",
                      display: entry["display"] as? String ?? "")
        }

        let bindings = (root["keyboard"] as? [String: Any])?["bindings"] as? [[String: Any]] ?? []
        shortcuts = Self.shortcutActions.map { item in
            let keys = bindings.last { ($0["action"] as? String) == item.action }?["keys"] as? String
            return Shortcut(title: item.title, action: item.action, keys: keys ?? "")
        }
        scratchpadApps = Self.scratchpadApps(from: bindings)
    }

    /// The apps with scratchpad shortcuts among `bindings`, in order of first appearance; the
    /// last binding of each of their two actions gives its keys.
    static func scratchpadApps(from bindings: [[String: Any]]) -> [ScratchpadApp] {
        var pads: [ScratchpadApp] = []
        for binding in bindings {
            guard let action = binding["action"] as? String, let keys = binding["keys"] as? String else { continue }
            let toggle = action.hasPrefix(togglePrefix)
            guard toggle || action.hasPrefix(tilePrefix) else { continue }
            let bundleID = String(action.dropFirst((toggle ? togglePrefix : tilePrefix).count))
            let index = pads.firstIndex { $0.bundleID == bundleID } ?? {
                pads.append(ScratchpadApp(bundleID: bundleID))
                return pads.count - 1
            }()
            if toggle { pads[index].toggleKeys = keys } else { pads[index].tileKeys = keys }
        }
        return pads
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        saveError = ConfigWriter.save { root in
            ConfigWriter.edit(&root, section: "tiling", saveTiling)
            ConfigWriter.edit(&root, section: "keyboard", saveBindings)
        }
    }

    /// The options, workspaces, floating and app rules.
    private func saveTiling(_ tiling: inout [String: Any]) {
        tiling["enabled"] = enabled
        tiling["layout"] = layout.rawValue
        tiling["gap"] = gap
        tiling["padding"] = padding
        tiling["mouseFollowsFocus"] = mouseFollowsFocus
        tiling["accordionPadding"] = accordionPadding == Int(Defaults.defaultAccordionPadding) ? nil : accordionPadding
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
            if !workspace.display.isEmpty { entry["display"] = workspace.display }
            return entry
        }
    }

    /// The window shortcuts and the scratchpad apps' shortcuts, in `keyboard.bindings`.
    private func saveBindings(_ keyboard: inout [String: Any]) {
        var desired: [(action: String, keys: String)] = shortcuts.map { (action: $0.action, keys: $0.keys) }
        for pad in scratchpadApps {
            desired.append((action: pad.toggleAction, keys: pad.toggleKeys))
            desired.append((action: pad.tileAction, keys: pad.tileKeys))
        }
        keyboard["bindings"] = Self.mergedBindings(keyboard["bindings"] as? [[String: Any]] ?? [], desired: desired,
                                                   scratchpadActions: Set(scratchpadApps.flatMap { [$0.toggleAction, $0.tileAction] }))
    }

    /// `bindings` with the `desired` keys of each action. Each action's last binding (the one
    /// the page shows) is edited in place, or removed when its keys are empty; an action with
    /// no binding gets one at the end; other bindings, even more for the same action, stay where
    /// they are. Scratchpad bindings not in `scratchpadActions` (an app taken off the list) go.
    static func mergedBindings(_ bindings: [[String: Any]], desired: [(action: String, keys: String)],
                               scratchpadActions: Set<String>) -> [[String: Any]] {
        func actionText(_ binding: [String: Any]) -> String { binding["action"] as? String ?? "" }
        var bindings = bindings
        bindings.removeAll {
            let action = actionText($0)
            return (action.hasPrefix(togglePrefix) || action.hasPrefix(tilePrefix)) && !scratchpadActions.contains(action)
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
        return bindings.enumerated().filter { !cleared.contains($0.offset) }.map(\.element) + added
    }
}
