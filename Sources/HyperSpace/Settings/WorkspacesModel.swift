import AppKit
import Combine

/// State of the Workspaces page: the workspaces with their shortcuts and display, and the app
/// rules. Changes go to the file through the shared `TilingModel`.
final class WorkspacesModel: ObservableObject {
    typealias Workspace = TilingModel.Workspace
    typealias Assignment = TilingModel.Assignment

    @Published private(set) var workspaces: [Workspace] = []
    /// Apps whose windows open in a given workspace.
    @Published private(set) var assignments: [Assignment] = []
    /// A workspace about to be removed, while the page asks to confirm.
    @Published private(set) var removal: TilingModel.Removal?
    /// The connected displays, for the workspaces' display menus: read when the window opens
    /// and when displays change, not on every redraw.
    @Published private(set) var screens = ScreenInfo.current()

    /// The writer the four window pages share.
    weak var store: TilingModel?
    /// A workspace name is saved shortly after the last keystroke.
    private let renameSave = Debouncer(delay: 0.5)
    /// What is typed in each workspace's name field: one object per row, so a keystroke redraws
    /// that row only, not the page.
    private var nameDrafts: [UUID: NameDraft] = [:]
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screens = ScreenInfo.current() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func edit(_ change: () -> Void) {
        guard let store else { return change() }
        store.edit(change)
    }

    /// A name is being typed: a reload waits for it.
    var isRenaming: Bool { renameSave.isPending }

    /// Every shortcut of the page, for the duplicate check.
    var shortcutKeys: [String] { workspaces.flatMap { [$0.switchKeys, $0.moveKeys] } }

    // MARK: - Workspaces

    func addWorkspace() {
        edit {
            // Its number, or the next free one should a workspace already be called that.
            let taken = Set(workspaces.map(\.name))
            let name = (workspaces.count...).lazy.map { TilingConfig.workspaceName(nil, at: $0) }.first { !taken.contains($0) }!
            let workspace = Workspace(name: name, switchKeys: "", moveKeys: "")
            workspaces.append(workspace)
            nameDrafts[workspace.id] = NameDraft(text: name)
        }
    }

    func setDisplay(_ display: String, for id: UUID) {
        edit { workspaces.update(id: id) { $0.display = display } }
    }

    /// The shortcut recorded for a workspace (called inside the store's `edit`).
    func setKeys(_ keys: String, for field: TilingModel.Field) {
        switch field {
        case .switchKeys(let id): workspaces.update(id: id) { $0.switchKeys = keys }
        case .moveKeys(let id): workspaces.update(id: id) { $0.moveKeys = keys }
        case .shortcut: break
        }
    }

    /// The remove button of a workspace: a workspace with shortcuts, app rules or a display pin
    /// is removed once confirmed (they all go with it), an empty one at once.
    func askToRemoveWorkspace(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let losses = TilingModel.removalLosses(of: workspace, assignments: assignments, appName: AppLauncher.name)
        if losses.isEmpty {
            removeWorkspace(id)
        } else {
            removal = TilingModel.Removal(id: id, name: workspace.name, losses: losses)
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
        store?.stopCapture()
        edit {
            (workspaces, assignments) = TilingModel.removing(id, from: workspaces, assignments: assignments)
            nameDrafts[id] = nil
        }
    }

    // MARK: - App rules

    func addAssignment(_ bundleID: String) {
        guard !assignments.contains(where: { $0.app == bundleID }), let first = workspaces.first else { return }
        edit { assignments.append(Assignment(app: bundleID, workspace: first.id, text: first.name)) }
    }

    func setAssignment(_ id: UUID, workspace: UUID) {
        edit { assignments.update(id: id) { $0.workspace = workspace } }
    }

    func removeAssignment(_ id: UUID) {
        edit { assignments.removeAll { $0.id == id } }
    }

    // MARK: - Names

    /// The name field of a workspace: what is typed there, kept per row. Every workspace has
    /// one from the moment it is loaded or added (`syncNameDrafts`), so a page's `body` only
    /// reads here.
    func nameDraft(for workspace: Workspace) -> NameDraft {
        nameDrafts[workspace.id] ?? NameDraft(text: workspace.name)
    }

    /// A keystroke in a name: saved shortly after the last one. A name that is empty or another
    /// workspace's is shown but not saved (see `TilingModel.nameWarning`). App rules follow by identity.
    func nameTyped() {
        renameSave.schedule { [weak self] in self?.edit {} }
    }

    /// The names typed and not saved yet, by workspace.
    func typedNames() -> [UUID: String] {
        var typed: [UUID: String] = [:]
        for workspace in workspaces {
            if let text = nameDrafts[workspace.id]?.text, TilingModel.trimmedName(text) != workspace.name { typed[workspace.id] = text }
        }
        return typed
    }

    /// After a reload: the names that were being typed are in their fields again.
    func restore(_ typed: [UUID: String]) {
        for (id, text) in typed { nameDrafts[id]?.text = text }
    }

    /// A save is about to start: the typed names that are valid become the workspaces' names
    /// (trimmed), and no later save is needed for them.
    func prepareToSave() {
        renameSave.cancel()
        var spaces = workspaces
        for index in spaces.indices {
            guard let text = nameDrafts[spaces[index].id].map({ TilingModel.trimmedName($0.text) }),
                  text != spaces[index].name else { continue }
            let others = Set(spaces.indices.filter { $0 != index }.map { spaces[$0].name })
            if TilingModel.isValidName(text, others: others) { spaces[index].name = text }
        }
        assignIfChanged(spaces, to: &workspaces)
    }

    // MARK: - Persistence

    /// Shows the `tiling` section of the file. Rows keep their ids while they mean the same:
    /// SwiftUI keeps them, and a focused name field its focus.
    func load(_ tiling: [String: Any]) {
        var spaces = (tiling["workspaces"] as? [[String: Any]] ?? []).enumerated().map { index, entry in
            Workspace(name: TilingConfig.workspaceName(entry["name"] as? String, at: index),
                      switchKeys: entry["switch"] as? String ?? "",
                      moveKeys: entry["move"] as? String ?? "",
                      display: TilingModel.pin(entry["display"] as? String ?? ""))
        }
        let spaceIDs = reusedIDs(for: spaces.map(\.name), from: workspaces.map { ($0.name, $0.id) })
        for index in spaces.indices { spaces[index].id = spaceIDs[index] }
        assignIfChanged(spaces, to: &workspaces)
        syncNameDrafts()

        var assigned = TilingModel.assignments(from: tiling["assign"] as? [[String: Any]] ?? [], workspaces: workspaces)
        let ruleIDs = reusedIDs(for: assigned.map { [$0.app, $0.text] }, from: assignments.map { ([$0.app, $0.text], $0.id) })
        for index in assigned.indices { assigned[index].id = ruleIDs[index] }
        assignIfChanged(assigned, to: &assignments)
    }

    /// The name fields show the names loaded: one per workspace, the rows of removed
    /// workspaces losing theirs.
    private func syncNameDrafts() {
        var drafts: [UUID: NameDraft] = [:]
        for workspace in workspaces {
            if let draft = nameDrafts[workspace.id] {
                assignIfChanged(workspace.name, to: &draft.text)
                drafts[workspace.id] = draft
            } else {
                drafts[workspace.id] = NameDraft(text: workspace.name)
            }
        }
        nameDrafts = drafts
    }
}

/// A workspace's name as typed in its field: its own object, so a keystroke redraws that row
/// (the field and its warning), not the whole Workspaces page.
final class NameDraft: ObservableObject {
    @Published var text: String

    init(text: String) {
        self.text = text
    }
}
