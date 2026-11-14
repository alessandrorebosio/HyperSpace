import AppKit
import Combine

/// State of the four window pages (Tiling, Workspaces, Window Rules, Shortcuts): layout
/// options, workspaces, floating and app rules, and window shortcuts. Every change is written
/// to config.json; the config watcher applies it.
final class TilingModel: ObservableObject, FileBackedModel {
    struct Workspace: Identifiable, Equatable {
        var id = UUID()
        /// The name saved: never empty, never another workspace's. What is being typed lives
        /// in the row's `NameDraft` until it is valid and saved.
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
    struct Shortcut: Equatable {
        let action: String
        var keys: String
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
    @Published private(set) var workspaces: [Workspace] = [] { didSet { duplicateCache = nil } }
    /// Bundle identifiers of apps whose windows are never tiled.
    @Published private(set) var floating: [String] = []
    @Published private(set) var floatingWindows: [FloatingWindowRule] = []
    /// The rule being written: its own object, so typing its title redraws that row only.
    let floatingDraft = FloatingRuleDraft()
    /// Apps whose windows open in a given workspace.
    @Published private(set) var assignments: [Assignment] = []
    /// The regular apps running, for the app menus: follows apps launching and quitting.
    @Published private(set) var runningApps = AppLauncher.runningApps

    /// An app rule. It follows its workspace by identity, so renaming the workspace (or typing
    /// a name another one has on the way) never moves it to another.
    struct Assignment: Identifiable, Equatable {
        var id = UUID()
        var app: String
        /// The workspace's `id`; nil when the file names none that exists (kept as written).
        var workspace: UUID?
        /// The workspace as written in the file ("web" or "2"): kept while it still means the same one.
        var text: String
    }
    @Published private(set) var shortcuts: [Shortcut] = [] { didSet { duplicateCache = nil } }
    /// The shortcuts used more than once, kept until the workspaces, shortcuts, scratchpad apps
    /// or other bindings change.
    private var duplicateCache: Set<String>?
    /// The keys of the bindings no page shows (launching an app, a second binding of an
    /// action): they count when shortcuts are checked for duplicates.
    private var otherBindingKeys: [String] = [] { didSet { duplicateCache = nil } }
    /// An app with its own scratchpad shortcuts: show/hide ("scratchpad <bundle id>") and
    /// into the tiling and back ("move-to-scratchpad <bundle id>").
    struct ScratchpadApp: Identifiable, Equatable {
        let bundleID: String
        var toggleKeys = ""
        var tileKeys = ""
        var id: String { bundleID }
        var toggleAction: String { TilingModel.togglePrefix + bundleID }
        var tileAction: String { TilingModel.tilePrefix + bundleID }
        var hasShortcut: Bool { !toggleKeys.isEmpty || !tileKeys.isEmpty }
    }
    @Published private(set) var scratchpadApps: [ScratchpadApp] = [] { didSet { duplicateCache = nil } }
    @Published private(set) var capturing: Field?

    /// A workspace about to be removed with what goes with it, while the page asks to confirm.
    struct Removal: Equatable {
        let id: UUID
        let name: String
        /// What goes with it, one line each: its shortcuts, its app rules, its display pin.
        let losses: [String]
    }
    @Published private(set) var removal: Removal?

    private let recorder: ShortcutRecorder
    /// A workspace name is saved shortly after the last keystroke.
    private let renameSave = Debouncer(delay: 0.5)
    /// What is typed in each workspace's name field: one object per row, so a keystroke redraws
    /// that row only, not the page.
    private var nameDrafts: [UUID: NameDraft] = [:]
    /// A slider value changed without a drag (arrow keys, VoiceOver) is saved shortly after.
    private let spacingSave = Debouncer(delay: 0.6)
    /// A slider is being dragged: saved on release.
    private var sliderHeld = false
    /// The tiling section and the bindings, and the options as loaded: only those changed since
    /// are written, so a key the user never set stays out of the file and a value the page
    /// rounds ("gap": 7.5) stays as written.
    private var sync = FileSync<Options>(SyncedSlice { root in
        ["tiling": ConfigWriter.section("tiling", of: root),
         "bindings": ConfigWriter.section("keyboard", of: root)["bindings"] ?? []]
    })
    var saveStatus: SaveStatus { sync.status }

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

    /// The connected displays, for the workspaces' display menus: read when the window opens
    /// and when displays change, not on every redraw.
    @Published private(set) var screens = ScreenInfo.current()
    private var observers: [NSObjectProtocol] = []

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        recorder = ShortcutRecorder(eventTap: eventTap)
        load(config)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screens = ScreenInfo.current() })
        observers.append(center.addObserver(forName: AppLauncher.runningAppsDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let apps = AppLauncher.runningApps
            if !apps.elementsEqual(runningApps, by: { $0 == $1 }) { runningApps = apps }
        })
    }

    /// Something is being edited: a reload now would undo it, so it waits for the edit to end.
    private var isEditing: Bool {
        capturing != nil || renameSave.isPending || spacingSave.isPending || sliderHeld
    }

    /// Follows the file, unless a shortcut is being recorded, a name typed or a slider moved.
    func reload(from root: [String: Any]) {
        if sync.shouldReload(root, editing: isEditing) { load(root) }
    }

    /// The window closes: nothing stays suspended, and a rename or slider change made just before is saved.
    func close() {
        stopCapture()
        if renameSave.isPending || spacingSave.isPending || sliderHeld {
            sliderHeld = false
            edit {}
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Editing

    func setEnabled(_ on: Bool) { guard enabled != on else { return }; edit { enabled = on } }
    func setLayout(_ kind: LayoutKind) { guard layout != kind else { return }; edit { layout = kind } }
    func setMouseFollowsFocus(_ on: Bool) { guard mouseFollowsFocus != on else { return }; edit { mouseFollowsFocus = on } }

    /// The slider setters show the value at once; it is saved when the slider is released, or
    /// shortly after a change made without dragging. A drag sends the same rounded value many
    /// times: only a change is published.
    func setGap(_ value: Int) { setSpacing(value.clamped(to: Self.spacingRange), \.gap) }
    func setPadding(_ value: Int) { setSpacing(value.clamped(to: Self.spacingRange), \.padding) }
    func setAccordionPadding(_ value: Int) { setSpacing(value.clamped(to: Self.accordionRange), \.accordionPadding) }

    private func setSpacing(_ value: Int, _ property: ReferenceWritableKeyPath<TilingModel, Int>) {
        guard self[keyPath: property] != value else { return }
        self[keyPath: property] = value
        if !sliderHeld { spacingSave.schedule { [weak self] in self?.commitSpacing() } }
    }

    /// A slider is grabbed or released: released, its value is saved (the config reload
    /// retiles once).
    func sliderEditing(_ editing: Bool) {
        sliderHeld = editing
        if editing {
            spacingSave.cancel()
        } else {
            commitSpacing()
        }
    }

    private func commitSpacing() {
        // The values shown, put back after a reload that was waiting for the slider.
        let shown = (gap: self.gap, padding: self.padding, accordion: self.accordionPadding)
        edit {
            gap = shown.gap
            padding = shown.padding
            accordionPadding = shown.accordion
        }
    }

    func addWorkspace() {
        edit {
            // Its number, or the next free one should a workspace already be called that.
            let taken = Set(workspaces.map(\.name))
            let name = (workspaces.count...).lazy.map { TilingConfig.workspaceName(nil, at: $0) }.first { !taken.contains($0) }!
            workspaces.append(Workspace(name: name, switchKeys: "", moveKeys: ""))
        }
    }

    func setDisplay(_ display: String, for id: UUID) {
        edit { workspaces.update(id: id) { $0.display = display } }
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

    /// The remove button of a workspace: a workspace with shortcuts, app rules or a display pin
    /// is removed once confirmed (they all go with it), an empty one at once.
    func askToRemoveWorkspace(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let losses = Self.removalLosses(of: workspace, assignments: assignments, appName: AppLauncher.name)
        if losses.isEmpty {
            removeWorkspace(id)
        } else {
            removal = Removal(id: id, name: workspace.name, losses: losses)
        }
    }

    func confirmRemoval() {
        guard let removal else { return }
        self.removal = nil
        removeWorkspace(removal.id)
    }

    func cancelRemoval() {
        assignIfChanged(nil, to: &removal)
    }

    private func removeWorkspace(_ id: UUID) {
        stopCapture()
        edit {
            (workspaces, assignments) = Self.removing(id, from: workspaces, assignments: assignments)
            nameDrafts[id] = nil
        }
    }

    /// The workspaces and app rules once workspace `id` is removed: its rules go with it (the
    /// file loses them too), rules naming no workspace stay as they were.
    static func removing(_ id: UUID, from workspaces: [Workspace], assignments: [Assignment])
        -> (workspaces: [Workspace], assignments: [Assignment]) {
        (workspaces.filter { $0.id != id }, assignments.filter { $0.workspace != id })
    }

    /// What goes when `workspace` is removed, one line each, for the confirmation.
    static func removalLosses(of workspace: Workspace, assignments: [Assignment], appName: (String) -> String) -> [String] {
        var losses: [String] = []
        let keys = [workspace.switchKeys, workspace.moveKeys].filter { !$0.isEmpty }
        if !keys.isEmpty {
            losses.append((keys.count == 1 ? "Its shortcut " : "Its shortcuts ") + keys.map(RemapTarget.label).joined(separator: " and "))
        }
        let apps = assignments.filter { $0.workspace == workspace.id }.map { appName($0.app) }
        if !apps.isEmpty {
            losses.append((apps.count == 1 ? "The app rule of " : "The app rules of ") + apps.joined(separator: ", "))
        }
        if !workspace.display.isEmpty { losses.append("Its display pin") }
        return losses
    }

    func removeFloating(_ bundleID: String) {
        edit { floating.removeAll { $0 == bundleID } }
    }

    func removeFloatingWindow(_ rule: FloatingWindowRule) {
        edit { floatingWindows.removeAll { $0 == rule } }
    }

    /// Adds the rule being written: an app without a title floats all its windows. A rule that
    /// already exists is not added (the page disables Add and says so).
    func addFloatingRule() {
        let app = floatingDraft.app, title = floatingDraft.trimmedTitle
        guard floatingDraft.canAdd,
              !Self.floatingRuleExists(app: app, title: title, floating: floating, floatingWindows: floatingWindows) else { return }
        if title.isEmpty {
            guard let app else { return }
            edit { floating.append(app) }
            floatingDraft.app = nil
        } else {
            guard let rule = TilingConfig.floatingRule(app: app, title: title) else { return }
            edit { floatingWindows.append(rule) }
            floatingDraft.title = ""
        }
    }

    /// Whether the rule for `app` (nil: any) and `title` (empty: every window) is already listed.
    static func floatingRuleExists(app: String?, title: String, floating: [String], floatingWindows: [FloatingWindowRule]) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return app.map(floating.contains) ?? false }
        guard let rule = TilingConfig.floatingRule(app: app, title: title) else { return false }
        return floatingWindows.contains(rule)
    }

    /// The running apps that are not in `taken` yet: what an Add App menu offers.
    static func candidates(_ apps: [(name: String, bundleID: String)], excluding taken: Set<String>) -> [(name: String, bundleID: String)] {
        apps.filter { !taken.contains($0.bundleID) }
    }

    var assignmentCandidates: [(name: String, bundleID: String)] {
        Self.candidates(runningApps, excluding: Set(assignments.map(\.app)))
    }

    var scratchpadCandidates: [(name: String, bundleID: String)] {
        Self.candidates(runningApps, excluding: Set(scratchpadApps.map(\.bundleID)))
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
        edit { scratchpadApps.removeAll { $0.bundleID == bundleID } }
    }

    func addAssignment(_ bundleID: String) {
        guard !assignments.contains(where: { $0.app == bundleID }), let first = workspaces.first else { return }
        edit { assignments.append(Assignment(app: bundleID, workspace: first.id, text: first.name)) }
    }

    func chooseAppForAssignment() {
        if let bundleID = chooseApp(prompt: "Assign") { addAssignment(bundleID) }
    }

    func setAssignment(_ id: UUID, workspace: UUID) {
        edit { assignments.update(id: id) { $0.workspace = workspace } }
    }

    func removeAssignment(_ id: UUID) {
        edit { assignments.removeAll { $0.id == id } }
    }

    // MARK: - Names

    /// The name field of a workspace: what is typed there, kept per row.
    func nameDraft(for workspace: Workspace) -> NameDraft {
        if let draft = nameDrafts[workspace.id] { return draft }
        let draft = NameDraft(text: workspace.name)
        nameDrafts[workspace.id] = draft
        return draft
    }

    /// A keystroke in a name: saved shortly after the last one. A name that is empty or another
    /// workspace's is shown but not saved (see `nameWarning`). App rules follow by identity.
    func nameTyped() {
        renameSave.schedule { [weak self] in self?.edit {} }
    }

    /// Why a typed name is not saved, if it is not.
    static func nameWarning(typed: String, saved: String, others: Set<String>) -> String? {
        guard typed != saved, !isValidName(typed, others: others) else { return nil }
        return typed.trimmingCharacters(in: .whitespaces).isEmpty
            ? "A workspace needs a name: \"\(saved)\" is kept"
            : "Another workspace has this name: \"\(saved)\" is kept"
    }

    static func isValidName(_ name: String, others: Set<String>) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !others.contains(name)
    }

    /// The names typed and not saved yet, by workspace.
    private func typedNames() -> [UUID: String] {
        var typed: [UUID: String] = [:]
        for workspace in workspaces {
            if let text = nameDrafts[workspace.id]?.text, text != workspace.name { typed[workspace.id] = text }
        }
        return typed
    }

    /// The typed names that are valid become the workspaces' names, for the save.
    private func foldTypedNames() {
        var spaces = workspaces
        for index in spaces.indices {
            guard let text = nameDrafts[spaces[index].id]?.text, text != spaces[index].name else { continue }
            let others = Set(spaces.indices.filter { $0 != index }.map { spaces[$0].name })
            if Self.isValidName(text, others: others) { spaces[index].name = text }
        }
        assignIfChanged(spaces, to: &workspaces)
    }

    // MARK: - Shortcuts

    /// Shortcuts used more than once, which only the last one would get. Compared by meaning:
    /// "hyper+h" is "cmd+alt+ctrl+shift+h", "esc" is "escape". Bindings the pages do not
    /// show count too.
    func isDuplicate(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }
        if duplicateCache == nil {
            let all = workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } + shortcuts.map(\.keys)
                + scratchpadApps.flatMap { [$0.toggleKeys, $0.tileKeys] } + otherBindingKeys
            duplicateCache = Self.duplicates(all)
        }
        return duplicateCache?.contains(Self.comboKey(keys)) ?? false
    }

    /// The shortcuts (as `comboKey`) found more than once in `keys`; empty keys do not count.
    static func duplicates(_ keys: [String]) -> Set<String> {
        var counts: [String: Int] = [:]
        for keys in keys where !keys.isEmpty { counts[comboKey(keys), default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
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

    /// The keys of the bindings no page shows: all but the last binding of each window
    /// shortcut and of each scratchpad action (the ones the pages show and edit).
    static func otherBindingKeys(_ bindings: [[String: Any]]) -> [String] {
        func action(_ binding: [String: Any]) -> String { binding["action"] as? String ?? "" }
        var shown = Set<Int>()
        for shortcut in shortcutActions {
            if let index = bindings.lastIndex(where: { sameAction(action($0), shortcut) }) { shown.insert(index) }
        }
        var lastScratchpad: [String: Int] = [:]
        for (index, binding) in bindings.enumerated() {
            let text = action(binding)
            if text.hasPrefix(togglePrefix) || text.hasPrefix(tilePrefix) { lastScratchpad[text] = index }
        }
        shown.formUnion(lastScratchpad.values)
        return bindings.indices.filter { !shown.contains($0) }.compactMap { bindings[$0]["keys"] as? String }
    }

    // MARK: - Capture

    /// Records the next shortcut pressed. Key bindings are paused so an existing
    /// shortcut reaches the window, but key remaps stay on, so caps lock → ⌃⌥⇧ counts.
    /// Escape alone cancels, Delete alone clears the shortcut.
    func startCapture(_ field: Field) {
        stopCapture(keeping: field)
        capturing = field
        recorder.startShortcut { [weak self] input in
            switch input {
            case .cancel: self?.stopCapture()
            case .clear: self?.finishCapture("")
            case .keys(let keys): self?.finishCapture(keys)
            }
        }
    }

    /// Recording ends with nothing recorded (Esc, the cap clicked again, another page, the
    /// window closed). A scratchpad app with no shortcut yet goes, since an app without
    /// shortcuts is not saved: the same rule as the incomplete rows of the other pages.
    func stopCapture() {
        stopCapture(keeping: nil)
    }

    /// `stopCapture`, keeping the scratchpad app of `next` (its other shortcut is recorded next).
    private func stopCapture(keeping next: Field?) {
        guard endCapture() else { return }
        scratchpadApps.removeAll { pad in
            !pad.hasShortcut && next != .shortcut(pad.toggleAction) && next != .shortcut(pad.tileAction)
        }
        applyDeferredReload()
    }

    /// Stops listening; false when nothing was being recorded.
    @discardableResult
    private func endCapture() -> Bool {
        recorder.stop()
        guard capturing != nil else { return false }
        capturing = nil
        return true
    }

    private func finishCapture(_ keys: String) {
        guard let field = capturing else { return }
        endCapture()
        edit {
            switch field {
            case .switchKeys(let id):
                workspaces.update(id: id) { $0.switchKeys = keys }
            case .moveKeys(let id):
                workspaces.update(id: id) { $0.moveKeys = keys }
            case .shortcut(let action):
                if let index = shortcuts.firstIndex(where: { $0.action == action }) { shortcuts[index].keys = keys }
                if let index = scratchpadApps.firstIndex(where: { $0.toggleAction == action }) { scratchpadApps[index].toggleKeys = keys }
                if let index = scratchpadApps.firstIndex(where: { $0.tileAction == action }) { scratchpadApps[index].tileKeys = keys }
                // Cleared both shortcuts, or never got one: not saved, so not listed either.
                scratchpadApps.removeAll { !$0.hasShortcut }
            }
        }
    }

    // MARK: - Persistence

    /// A reload skipped while editing, done now: names being typed stay as typed.
    private func applyDeferredReload() {
        guard let root = sync.takeDeferredReload() else { return }
        let typed = typedNames()
        load(root)
        for (id, text) in typed { nameDrafts[id]?.text = text }
    }

    /// A change made here: a reload skipped while editing comes first, so the save that
    /// follows writes the file's latest lists with the change.
    private func edit(_ change: () -> Void) {
        applyDeferredReload()
        change()
        save()
    }

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
        assignIfChanged(options.enabled, to: &enabled)
        assignIfChanged(options.layout, to: &layout)
        assignIfChanged(options.gap, to: &gap)
        assignIfChanged(options.padding, to: &padding)
        assignIfChanged(options.accordionPadding, to: &accordionPadding)
        assignIfChanged(options.mouseFollowsFocus, to: &mouseFollowsFocus)
        assignIfChanged(options.floating, to: &self.floating)
        assignIfChanged(options.floatingWindows, to: &floatingWindows)

        // Rows keep their ids while they mean the same (P8): SwiftUI keeps them, and a focused
        // name field its focus.
        var spaces = (tiling["workspaces"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
            Workspace(name: TilingConfig.workspaceName(entry["name"] as? String, at: index),
                      switchKeys: entry["switch"] as? String ?? "",
                      moveKeys: entry["move"] as? String ?? "",
                      display: entry["display"] as? String ?? "")
        }
        let spaceIDs = reusedIDs(for: spaces.map(\.name), from: workspaces.map { ($0.name, $0.id) })
        for index in spaces.indices { spaces[index].id = spaceIDs[index] }
        assignIfChanged(spaces, to: &workspaces)
        syncNameDrafts()

        var assigned = Self.assignments(from: tiling["assign"] as? [[String: Any]] ?? [], workspaces: workspaces)
        let ruleIDs = reusedIDs(for: assigned.map { [$0.app, $0.text] }, from: assignments.map { ([$0.app, $0.text], $0.id) })
        for index in assigned.indices { assigned[index].id = ruleIDs[index] }
        assignIfChanged(assigned, to: &assignments)

        let bindings = ConfigWriter.section("keyboard", of: root)["bindings"] as? [[String: Any]] ?? []
        assignIfChanged(Self.shortcutActions.map { action in
            let keys = bindings.last { Self.sameAction($0["action"] as? String ?? "", action) }?["keys"] as? String
            return Shortcut(action: action, keys: keys ?? "")
        }, to: &shortcuts)
        // A scratchpad app being recorded has no binding yet: it stays.
        let pads = Self.scratchpadApps(from: bindings)
        let recording = scratchpadApps.filter { pad in !pad.hasShortcut && !pads.contains { $0.bundleID == pad.bundleID } }
        assignIfChanged(pads + recording, to: &scratchpadApps)
        assignIfChanged(Self.otherBindingKeys(bindings), to: &otherBindingKeys)
        sync.didLoad(root, options)
    }

    /// The name fields show the names loaded; the rows of removed workspaces lose theirs.
    private func syncNameDrafts() {
        for (id, draft) in nameDrafts {
            if let workspace = workspaces.first(where: { $0.id == id }) {
                assignIfChanged(workspace.name, to: &draft.text)
            } else {
                nameDrafts[id] = nil
            }
        }
    }

    /// The app rules of the file, each pointing at its workspace the way the config resolves it
    /// (by name, else by number).
    static func assignments(from entries: [[String: Any]], workspaces: [Workspace]) -> [Assignment] {
        let names = workspaces.map(\.name)
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
        let names = workspaces.map(\.name)
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
        spacingSave.cancel()
        foldTypedNames()
        let old = sync.loaded
        sync.save(options) { root in
            ConfigWriter.edit(&root, section: "tiling") { saveTiling(&$0, old: old) }
            ConfigWriter.edit(&root, section: "keyboard", saveBindings)
        }
    }

    /// The options changed since the load (`old`), the workspaces, floating and app rules.
    /// Empty lists are left out, like every list the pages write.
    private func saveTiling(_ tiling: inout [String: Any], old: Options?) {
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
        let bindings = Self.mergedBindings(keyboard["bindings"] as? [[String: Any]] ?? [], desired: desired,
                                           scratchpadActions: Set(scratchpadApps.flatMap { [$0.toggleAction, $0.tileAction] }))
        keyboard["bindings"] = bindings.isEmpty ? nil : bindings
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

extension TilingModel: CaptureModel {}

/// The floating rule being written on the Window Rules page: app (nil for any) and title text.
final class FloatingRuleDraft: ObservableObject {
    @Published var app: String?
    @Published var title = ""

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }

    /// A rule needs an app, a title, or both.
    var canAdd: Bool { app != nil || !trimmedTitle.isEmpty }
}

/// A workspace's name as typed in its field: its own object, so a keystroke redraws that row
/// (the field and its warning), not the whole Workspaces page.
final class NameDraft: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}
