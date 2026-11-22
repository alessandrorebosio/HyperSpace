import AppKit
import Combine

/// What the four window pages share: the one writer of the `tiling` section and of
/// `keyboard.bindings`, the shortcut being recorded, and the shortcuts used twice. Each page
/// has its own model (`TilingOptionsModel`, `WorkspacesModel`, `WindowRulesModel`,
/// `ShortcutsModel`) that holds what the page shows, so a change redraws its page only; all
/// of them change the file through here (`edit`), which keeps the rules of every settings
/// model in one place: a reload that waited comes first, the file is read afresh and only what
/// changed since the load is written, so one page never writes over another's change.
///
/// The types of the window pages and their rules as pure functions (`TilingModel+Rules.swift`)
/// are namespaced here.
final class TilingModel: FileBackedModel {
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
        /// Shown after a separator: the first of the monitors by name.
        var startsGroup = false
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

    /// A workspace about to be removed with what goes with it, while the page asks to confirm.
    struct Removal: Equatable {
        let id: UUID
        let name: String
        /// What goes with it, one line each: its shortcuts, its app rules, its display pin.
        let losses: [String]
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

    static let togglePrefix = "scratchpad "
    static let tilePrefix = "move-to-scratchpad "

    /// The slider ranges (the config accepts the same ones).
    static let spacingRange = Int(TilingConfig.spacingRange.lowerBound)...Int(TilingConfig.spacingRange.upperBound)
    static let accordionRange = Int(TilingConfig.accordionPaddingRange.lowerBound)...Int(TilingConfig.accordionPaddingRange.upperBound)

    // MARK: - The pages

    /// The Tiling page (and the *Tiling is off* notice of the other three).
    let options = TilingOptionsModel()
    /// The Workspaces page: workspaces and app rules.
    let workspaces = WorkspacesModel()
    /// The Window Rules page: floating rules and scratchpad apps.
    let rules = WindowRulesModel()
    /// The Shortcuts page.
    let shortcuts = ShortcutsModel()
    /// The shortcuts used more than once, whichever page they are on.
    let conflicts = ShortcutConflicts()
    /// The regular apps running, for the app menus of two pages.
    let apps = RunningApps()
    /// The shortcut being recorded: its own object, so starting or ending a capture redraws
    /// the caps through it alone.
    let capture: FieldCapture<Field>

    /// What the pages write to the `tiling` section, as loaded: each part is written only once
    /// it differs, so a key the user never set stays out of the file and a value the page
    /// rounds ("gap": 7.5) stays as written.
    struct Snapshot {
        var options: TilingOptionsModel.Values
        var floating: [String]
        var floatingWindows: [FloatingWindowRule]
        /// The workspaces and the app rules, in the file's form.
        var workspaces: [[String: Any]]
        var assign: [[String: Any]]
    }

    /// The tiling section and the bindings.
    var sync = FileSync<Snapshot>(SyncedSlice { root in
        ["tiling": ConfigWriter.section("tiling", of: root),
         "bindings": ConfigWriter.section("keyboard", of: root)["bindings"] ?? []]
    })

    /// The keys of the bindings no page shows (launching an app, a second binding of an
    /// action): they count when shortcuts are checked for duplicates.
    private var otherBindingKeys: [String] = []

    /// `config`: the file as `ConfigWriter.readIfValid()` returns it.
    init(eventTap: EventTap, config: [String: Any]) {
        capture = FieldCapture(recorder: ShortcutRecorder(eventTap: eventTap))
        options.store = self
        workspaces.store = self
        rules.store = self
        shortcuts.store = self
        // A capture that ends with nothing recorded: a scratchpad app with no shortcut yet goes
        // (an app without shortcuts is not saved), except the one whose shortcut is recorded
        // next: the same rule as the incomplete rows of the other pages.
        capture.onEnd = { [weak self] next in
            guard let self else { return }
            rules.dropAppsWithoutShortcut(keeping: next)
            applyDeferredReload()
        }
        load(config)
    }

    /// A shortcut is being recorded, a name typed or a slider moved: a reload now would undo
    /// it, so it waits for the edit to end.
    var isEditing: Bool {
        capturing != nil || workspaces.isRenaming || options.isAdjusting
    }

    /// The window closes: nothing stays suspended, and a rename or slider change made just before is saved.
    func close() {
        stopCapture()
        if workspaces.isRenaming || options.isAdjusting {
            options.releaseSlider()
            edit {}
        }
    }

    // MARK: - Shortcuts

    /// Shortcuts used more than once, which only the last one would get. Compared by meaning:
    /// "hyper+h" is "cmd+alt+ctrl+shift+h", "esc" is "escape". Bindings the pages do not
    /// show count too.
    func isDuplicate(_ keys: String) -> Bool {
        !keys.isEmpty && conflicts.duplicates.contains(Self.comboKey(keys))
    }

    /// Every shortcut of the window pages and of the bindings no page shows, checked again.
    private func refreshConflicts() {
        conflicts.update(Self.duplicates(workspaces.shortcutKeys + shortcuts.shortcutKeys + rules.shortcutKeys + otherBindingKeys))
    }

    /// Records the next shortcut pressed. Key bindings are paused so an existing
    /// shortcut reaches the window, but key remaps stay on, so caps lock → ⌃⌥⇧ counts.
    /// Escape alone cancels, Delete alone clears the shortcut; a key that types on its own is
    /// refused (as a global shortcut it could no longer be typed).
    func startCapture(_ field: Field) {
        capture.begin(field)
        capture.recorder.startShortcut(refusingTypingKeys: true) { [weak self] input in
            switch input {
            case .cancel: self?.stopCapture()
            case .clear: self?.finishCapture("")
            case .keys(let keys): self?.finishCapture(keys)
            }
        }
    }

    private func finishCapture(_ keys: String) {
        guard let field = capturing else { return }
        capture.end()
        edit {
            switch field {
            case .switchKeys, .moveKeys:
                workspaces.setKeys(keys, for: field)
            case .shortcut(let action):
                shortcuts.setKeys(keys, for: action)
                rules.setKeys(keys, for: action)
            }
        }
    }

    // MARK: - Persistence

    /// A reload skipped while editing, done now: names being typed stay as typed.
    func applyDeferredReload() {
        guard let root = sync.takeDeferredReload() else { return }
        let typed = workspaces.typedNames()
        load(root)
        workspaces.restore(typed)
    }

    func load(_ root: [String: Any]) {
        let tiling = ConfigWriter.section("tiling", of: root)
        let bindings = ConfigWriter.section("keyboard", of: root)["bindings"] as? [[String: Any]] ?? []
        options.load(tiling)
        workspaces.load(tiling)
        rules.load(tiling, bindings: bindings)
        shortcuts.load(bindings)
        otherBindingKeys = Self.otherBindingKeys(bindings)
        refreshConflicts()
        sync.didLoad(root, snapshot)
    }

    private var snapshot: Snapshot {
        Snapshot(options: options.values, floating: rules.floating, floatingWindows: rules.floatingWindows,
                 workspaces: Self.workspaceEntries(workspaces.workspaces),
                 assign: Self.assignEntries(workspaces.assignments, workspaces: workspaces.workspaces))
    }

    func save() {
        workspaces.prepareToSave()
        options.prepareToSave()
        refreshConflicts()
        let old = sync.loaded
        let current = snapshot
        sync.save(current) { root in
            ConfigWriter.amend(&root, section: "tiling") { Self.write(current, to: &$0, since: old) }
            ConfigWriter.amend(&root, section: "keyboard", saveBindings)
        }
    }

    /// The options, workspaces, floating and app rules that changed since the load (`old`).
    /// An option never changed stays out of the file (or as it is written there); a list is
    /// written whole once it differs, an empty one left out.
    private static func write(_ new: Snapshot, to tiling: inout [String: Any], since old: Snapshot?) {
        TilingOptionsModel.write(new.options, to: &tiling, since: old?.options)
        tiling.writeList("floating", new.floating, since: old?.floating)
        func entries(_ rules: [FloatingWindowRule]) -> [[String: Any]] {
            rules.map { rule in
                var entry: [String: Any] = ["title": rule.title]
                if let app = rule.app { entry["app"] = app }
                return entry
            }
        }
        tiling.writeList("floatingWindows", entries(new.floatingWindows), since: old.map { entries($0.floatingWindows) })
        tiling.writeList("assign", new.assign, since: old?.assign)
        tiling.writeList("workspaces", new.workspaces, since: old?.workspaces)
    }

    /// The window shortcuts and the scratchpad apps' shortcuts, in `keyboard.bindings`: merged
    /// into the bindings the file holds now, so the ones no page shows stay as they are.
    private func saveBindings(_ keyboard: inout [String: Any]) {
        var desired: [(action: String, keys: String)] = shortcuts.shortcuts.map { (action: $0.action, keys: $0.keys) }
        for pad in rules.scratchpadApps {
            desired.append((action: pad.toggleAction, keys: pad.toggleKeys))
            desired.append((action: pad.tileAction, keys: pad.tileKeys))
        }
        let bindings = Self.mergedBindings(keyboard["bindings"] as? [[String: Any]] ?? [], desired: desired,
                                           scratchpadActions: Set(rules.scratchpadApps.flatMap { [$0.toggleAction, $0.tileAction] }))
        keyboard["bindings"] = bindings.isEmpty ? nil : bindings
    }
}

extension TilingModel: CaptureModel {}

/// The shortcuts used more than once on the window pages (as `TilingModel.comboKey`). Its own
/// object: the pages with shortcut caps observe it, so a duplicate that comes or goes with a
/// change on another page (or in the file) still shows.
final class ShortcutConflicts: ObservableObject {
    @Published private(set) var duplicates: Set<String> = []

    func update(_ duplicates: Set<String>) {
        assignIfChanged(duplicates, to: &self.duplicates)
    }
}

/// The regular apps running, one entry per app, for the app menus: follows apps launching and
/// quitting while the window is open.
final class RunningApps: ObservableObject {
    @Published private(set) var list = TilingModel.uniqueApps(AppLauncher.runningApps)
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: AppLauncher.runningAppsDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let apps = TilingModel.uniqueApps(AppLauncher.runningApps)
            if !apps.elementsEqual(list, by: { $0 == $1 }) { list = apps }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The running apps that are not in `taken` yet: what an Add App menu offers.
    func candidates(excluding taken: [String]) -> [(name: String, bundleID: String)] {
        TilingModel.candidates(list, excluding: Set(taken))
    }
}
