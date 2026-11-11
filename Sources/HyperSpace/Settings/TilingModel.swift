import AppKit
import Combine

/// State of the four window pages (Tiling, Workspaces, Window Rules, Shortcuts): layout
/// options, workspaces, floating and app rules, and window shortcuts. Every change is written
/// to config.json; the config watcher applies it.
final class TilingModel: ObservableObject, FileBackedModel {
    struct Workspace: Identifiable, Equatable {
        let id = UUID()
        /// The name as typed.
        var name: String
        /// The last valid name (not empty, not another workspace's): the one saved, so a name
        /// half-typed or taken never reaches the file.
        var savedName: String
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
    static let shortcutActions: [String] = {
        var all: [String] = []
        for group in pairedShortcuts {
            for row in group.rows { all += [row.actions.0, row.actions.1] }
        }
        for group in singleShortcuts { all += group.items.map(\.action) }
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
    /// The rule being written: its own object, so typing its title redraws that row only.
    let floatingDraft = FloatingRuleDraft()
    /// Apps whose windows open in a given workspace.
    @Published private(set) var assignments: [Assignment] = []

    /// An app rule. It follows its workspace by identity, so renaming the workspace (or typing
    /// a name another one has on the way) never moves it to another.
    struct Assignment: Identifiable, Equatable {
        let id = UUID()
        var app: String
        /// The workspace's `id`; nil when the file names none that exists (kept as written).
        var workspace: UUID?
        /// The workspace as written in the file ("web" or "2"): kept while it still means the same one.
        var text: String
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
    /// A workspace name is saved shortly after the last keystroke.
    private let renameSave = Debouncer(delay: 0.5)
    /// The tiling section and the bindings, as last read or written.
    private var synced = SyncedSlice { root in
        ["tiling": ConfigWriter.section("tiling", of: root),
         "bindings": ConfigWriter.section("keyboard", of: root)["bindings"] ?? []]
    }
    /// The options as loaded: only those changed since are written, so a key the user never set
    /// stays out of the file and a value the page rounds ("gap": 7.5) stays as written.
    private var loaded: Options?

    private struct Options: Equatable {
        var enabled: Bool
        var layout: LayoutKind
        var gap, padding, accordionPadding: Int
        var mouseFollowsFocus: Bool
        var floating: [String]
        var floatingWindows: [FloatingWindowRule]
    }

    private var options: Options {
        Options(enabled: enabled, layout: layout, gap: gap, padding: padding, accordionPadding: accordionPadding,
                mouseFollowsFocus: mouseFollowsFocus, floating: floating, floatingWindows: floatingWindows)
    }

    /// `config`: the file as `ConfigWriter.read()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        self.eventTap = eventTap
        load(config)
    }

    /// Follows the file, unless a shortcut is being recorded or a name typed.
    func reload(from root: [String: Any]) {
        guard capturing == nil, !renameSave.isPending, synced.changed(in: root) else { return }
        load(root)
    }

    deinit {
        stopCapture()
        // A rename typed just before closing the window is still saved.
        if renameSave.isPending { save() }
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) { guard enabled != on else { return }; enabled = on; save() }
    func setLayout(_ kind: LayoutKind) { guard layout != kind else { return }; layout = kind; save() }
    /// The slider setters only update the shown value; `commitSpacing` writes them.
    /// A drag sends the same rounded value many times: only a change is published (each
    /// `@Published` assignment redraws the page, equal or not).
    func setGap(_ value: Int) { Self.assign(value.clamped(to: Self.spacingRange), to: &gap) }
    func setPadding(_ value: Int) { Self.assign(value.clamped(to: Self.spacingRange), to: &padding) }
    func setAccordionPadding(_ value: Int) { Self.assign(value.clamped(to: Self.accordionRange), to: &accordionPadding) }

    private static func assign(_ value: Int, to property: inout Int) {
        if property != value { property = value }
    }
    /// Writes the current slider values (the config reload retiles once, on release).
    func commitSpacing() { save() }
    func setMouseFollowsFocus(_ on: Bool) { guard mouseFollowsFocus != on else { return }; mouseFollowsFocus = on; save() }

    func addWorkspace() {
        // Its number, or the next free one should a workspace already be called that.
        let taken = Set(workspaces.map(\.savedName))
        let name = (workspaces.count...).lazy.map { TilingConfig.workspaceName(nil, at: $0) }.first { !taken.contains($0) }!
        workspaces.append(Workspace(name: name, savedName: name, switchKeys: "", moveKeys: ""))
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
        guard let rule = TilingConfig.floatingRule(app: floatingDraft.app, title: floatingDraft.trimmedTitle),
              !floatingWindows.contains(rule) else { return }
        floatingWindows.append(rule)
        floatingDraft.title = ""
        save()
    }

    func removeFloatingWindow(_ rule: FloatingWindowRule) {
        floatingWindows.removeAll { $0 == rule }
        save()
    }

    /// Adds the rule being written: an app without a title floats all its windows.
    func addFloatingRule() {
        guard floatingDraft.trimmedTitle.isEmpty else { return addFloatingWindow() }
        guard let app = floatingDraft.app else { return }
        addFloating(app)
        floatingDraft.app = nil
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
        assignments.append(Assignment(app: bundleID, workspace: first.id, text: first.savedName))
        save()
    }

    func chooseAppForAssignment() {
        if let bundleID = chooseApp(prompt: "Assign") { addAssignment(bundleID) }
    }

    func setAssignment(_ id: UUID, workspace: UUID) {
        if assignments.update(id: id, { $0.workspace = workspace }) { save() }
    }

    func removeAssignment(_ id: UUID) {
        assignments.removeAll { $0.id == id }
        save()
    }

    /// Typing a name saves shortly after the last keystroke; a name that is empty or another
    /// workspace's is shown but not saved (see `nameWarning`). App rules follow by identity.
    func rename(_ id: UUID, to name: String) {
        let others = Set(workspaces.filter { $0.id != id }.map(\.savedName))
        let valid = Self.isValidName(name, others: others)
        guard workspaces.update(id: id, { $0.name = name; if valid { $0.savedName = name } }) else { return }
        renameSave.schedule { [weak self] in self?.save() }
    }

    /// Why a typed name is not saved, if it is not.
    func nameWarning(for workspace: Workspace) -> String? {
        guard workspace.name != workspace.savedName else { return nil }
        return workspace.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "A workspace needs a name: \"\(workspace.savedName)\" is kept"
            : "Another workspace has this name: \"\(workspace.savedName)\" is kept"
    }

    static func isValidName(_ name: String, others: Set<String>) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !others.contains(name)
    }

    /// Shortcuts used more than once, which only the last one would get. Compared by meaning:
    /// "hyper+h" is "cmd+alt+ctrl+shift+h", "esc" is "escape".
    func isDuplicate(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }
        if duplicateCache == nil {
            var counts: [String: Int] = [:]
            let all = workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } + shortcuts.map(\.keys)
                + scratchpadApps.flatMap { [$0.toggleKeys, $0.tileKeys] }
            for keys in all where !keys.isEmpty { counts[Self.comboKey(keys), default: 0] += 1 }
            duplicateCache = Set(counts.filter { $0.value > 1 }.keys)
        }
        return duplicateCache?.contains(Self.comboKey(keys)) ?? false
    }

    /// What a shortcut means, to compare two: its key code and modifiers, or the text itself
    /// when it does not parse.
    static func comboKey(_ keys: String) -> String {
        guard let combo = try? KeyCombo.parse(keys) else { return keys }
        return "\(combo.keyCode)/\(combo.modifiers.rawValue)"
    }

    /// Whether two action texts mean the same action ("Focus Left" and "focus left",
    /// "resize width 50" and "resize width +50"); texts that do not parse compare as text.
    static func sameAction(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = try? Action.parse(a), let y = try? Action.parse(b) else { return false }
        return x == y
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
            case ("escape", true): cancelCapture()
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

    /// Escape: nothing recorded. A scratchpad app just added with no shortcut yet goes again,
    /// since an app without shortcuts is not saved.
    private func cancelCapture() {
        if case .shortcut(let action) = capturing,
           let pad = scratchpadApps.first(where: { $0.toggleAction == action }),
           pad.toggleKeys.isEmpty, pad.tileKeys.isEmpty {
            scratchpadApps.removeAll { $0.bundleID == pad.bundleID }
        }
        stopCapture()
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

    private func load(_ root: [String: Any]) {
        let tiling = ConfigWriter.section("tiling", of: root)
        func number(_ key: String, _ range: ClosedRange<CGFloat>, _ fallback: CGFloat) -> Int {
            Int(TilingConfig.value((tiling[key] as? NSNumber)?.doubleValue, range, fallback))
        }
        // The config clamps the numbers too: what a hand-edited file holds shows as it will apply.
        var floating: [String] = []
        for app in tiling["floating"] as? [String] ?? [] where !floating.contains(app) { floating.append(app) }
        // The rules as the config reads them; one listed twice shows once (the lists are keyed by rule).
        var rules: [FloatingWindowRule] = []
        for entry in tiling["floatingWindows"] as? [[String: Any]] ?? [] {
            guard let title = entry["title"] as? String,
                  let rule = TilingConfig.floatingRule(app: entry["app"] as? String, title: title),
                  !rules.contains(rule) else { continue }
            rules.append(rule)
        }
        let options = Options(
            enabled: tiling["enabled"] as? Bool ?? Defaults.defaultEnabled,
            layout: (tiling["layout"] as? String).flatMap { LayoutKind(configText: $0) } ?? Defaults.defaultLayout,
            gap: number("gap", Defaults.spacingRange, Defaults.defaultGap),
            padding: number("padding", Defaults.spacingRange, Defaults.defaultPadding),
            accordionPadding: number("accordionPadding", Defaults.accordionPaddingRange, Defaults.defaultAccordionPadding),
            mouseFollowsFocus: tiling["mouseFollowsFocus"] as? Bool ?? Defaults.defaultMouseFollowsFocus,
            floating: floating, floatingWindows: rules)
        if self.options != options {
            enabled = options.enabled
            layout = options.layout
            gap = options.gap
            padding = options.padding
            accordionPadding = options.accordionPadding
            mouseFollowsFocus = options.mouseFollowsFocus
            self.floating = options.floating
            floatingWindows = options.floatingWindows
        }
        loaded = options

        workspaces = (tiling["workspaces"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
            let name = TilingConfig.workspaceName(entry["name"] as? String, at: index)
            return Workspace(name: name, savedName: name,
                             switchKeys: entry["switch"] as? String ?? "",
                             moveKeys: entry["move"] as? String ?? "",
                             display: entry["display"] as? String ?? "")
        }
        assignments = Self.assignments(from: tiling["assign"] as? [[String: Any]] ?? [], workspaces: workspaces)

        let bindings = ConfigWriter.section("keyboard", of: root)["bindings"] as? [[String: Any]] ?? []
        shortcuts = Self.shortcutActions.map { action in
            let keys = bindings.last { Self.sameAction($0["action"] as? String ?? "", action) }?["keys"] as? String
            return Shortcut(action: action, keys: keys ?? "")
        }
        scratchpadApps = Self.scratchpadApps(from: bindings)
        synced.record(root)
    }

    /// The app rules of the file, each pointing at its workspace the way the config resolves it
    /// (by name, else by number).
    static func assignments(from entries: [[String: Any]], workspaces: [Workspace]) -> [Assignment] {
        let names = workspaces.map(\.savedName)
        return entries.compactMap { entry in
            guard let app = entry["app"] as? String, let text = entry["workspace"] as? String else { return nil }
            let index = TilingConfig.workspaceIndex(text, names: names)
            return Assignment(app: app, workspace: index.map { workspaces[$0].id }, text: text)
        }
    }

    /// The app rules as written: a rule keeps its text while it still points at its workspace
    /// ("2" stays "2"), else gets the workspace's name. Rules of a removed workspace go; a rule
    /// that named no workspace to begin with stays as it was (the config reports it).
    static func assignEntries(_ assignments: [Assignment], workspaces: [Workspace]) -> [[String: Any]] {
        let names = workspaces.map(\.savedName)
        return assignments.compactMap { rule in
            guard let id = rule.workspace else { return ["app": rule.app, "workspace": rule.text] }
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
            let keepsText = TilingConfig.workspaceIndex(rule.text, names: names) == index
            return ["app": rule.app, "workspace": keepsText ? rule.text : names[index]]
        }
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
        renameSave.cancel()
        let error = ConfigWriter.save(recording: &synced) { root in
            ConfigWriter.edit(&root, section: "tiling", saveTiling)
            ConfigWriter.edit(&root, section: "keyboard", saveBindings)
        }
        if error == nil { loaded = options }
        Optional.assignChange(error, to: &saveError)
    }

    /// The options changed since the load, the workspaces, floating and app rules.
    private func saveTiling(_ tiling: inout [String: Any]) {
        let old = loaded
        if enabled != old?.enabled { tiling["enabled"] = enabled }
        if layout != old?.layout { tiling["layout"] = layout.rawValue }
        if gap != old?.gap { tiling["gap"] = gap }
        if padding != old?.padding { tiling["padding"] = padding }
        if mouseFollowsFocus != old?.mouseFollowsFocus { tiling["mouseFollowsFocus"] = mouseFollowsFocus }
        if accordionPadding != old?.accordionPadding { tiling["accordionPadding"] = accordionPadding }
        if floating != old?.floating { tiling["floating"] = floating.isEmpty ? nil : floating }
        if floatingWindows != old?.floatingWindows {
            tiling["floatingWindows"] = floatingWindows.isEmpty ? nil : floatingWindows.map { rule -> [String: Any] in
                var entry: [String: Any] = ["title": rule.title]
                if let app = rule.app { entry["app"] = app }
                return entry
            }
        }
        let rules = Self.assignEntries(assignments, workspaces: workspaces)
        tiling["assign"] = rules.isEmpty ? nil : rules
        tiling["workspaces"] = workspaces.isEmpty ? nil : workspaces.map { workspace -> [String: Any] in
            var entry: [String: Any] = ["name": workspace.savedName]
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
        func sameAction(_ binding: [String: Any], _ action: String) -> Bool { Self.sameAction(actionText(binding), action) }
        var bindings = bindings
        bindings.removeAll {
            let action = actionText($0)
            return (action.hasPrefix(togglePrefix) || action.hasPrefix(tilePrefix)) && !scratchpadActions.contains(action)
        }
        var cleared = Set<Int>()
        var added: [[String: Any]] = []
        for entry in desired {
            if let index = bindings.lastIndex(where: { sameAction($0, entry.action) }) {
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

/// The floating rule being written on the Window Rules page: app (nil for any) and title text.
final class FloatingRuleDraft: ObservableObject {
    @Published var app: String?
    @Published var title = ""

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

    /// A rule needs an app, a title, or both.
    var canAdd: Bool { app != nil || !trimmedTitle.isEmpty }
}
