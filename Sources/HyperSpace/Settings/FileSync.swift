import Combine
import Foundation

/// The part of config.json a settings model shows, as it was when the model last read or wrote
/// it. When the file changes the model reloads only if that part changed, so its own saves cost
/// nothing and an edit made elsewhere (an editor, the menu bar) shows up instead of being
/// overwritten by the model's next save.
struct SyncedSlice {
    private let extract: ([String: Any]) -> [String: Any]
    private var value = NSDictionary()

    init(_ extract: @escaping ([String: Any]) -> [String: Any]) {
        self.extract = extract
    }

    /// A slice made of whole top-level sections.
    init(sections: String...) {
        self.init { root in root.filter { sections.contains($0.key) } }
    }

    mutating func record(_ root: [String: Any]) {
        value = NSDictionary(dictionary: extract(root))
    }

    func changed(in root: [String: Any]) -> Bool {
        !value.isEqual(to: extract(root))
    }
}

extension ConfigWriter {
    /// `save`, also handing back the whole file as written, for `SyncedSlice.record`.
    static func save(recording slice: inout SyncedSlice, _ change: (inout [String: Any]) -> Void) -> String? {
        var written: [String: Any]?
        let error = save { root in
            change(&root)
            written = root
        }
        if error == nil, let written { slice.record(written) }
        return error
    }

    /// Changes one top-level object of `root`, like `edit`, but a section that is missing and
    /// still empty after `change` stays out of the file: a save that finds nothing to write
    /// leaves the file as it is.
    static func amend(_ root: inout [String: Any], section key: String, _ change: (inout [String: Any]) -> Void) {
        var section = self.section(key, of: root)
        change(&section)
        if !section.isEmpty || root[key] != nil { root[key] = section }
    }
}

/// What keeps a model's pages from saving, shown as a notice at the top of them. Its own
/// object, so a problem that comes or goes redraws the notice only.
final class SaveStatus: ObservableObject {
    struct Problem: Equatable {
        let message: String
        /// A change made on the page was not saved; false when the file could not be read to
        /// begin with and nothing was changed yet.
        let unsavedChange: Bool

        var title: String { unsavedChange ? "Changes not saved" : "Config file cannot be read" }
    }

    @Published private(set) var problem: Problem?

    var error: String? { problem?.message }

    /// The result of a save: its error, or nil when it was written.
    func set(_ error: String?) {
        assignIfChanged(error.map { Problem(message: $0, unsavedChange: true) }, to: &problem)
    }

    /// The window opened on a file that does not parse, or that cannot be read at all
    /// (`message` says which): the pages show nothing of it.
    func setUnreadable(_ message: String = ConfigWriter.SyntaxError.message) {
        assignIfChanged(Problem(message: message, unsavedChange: false), to: &problem)
    }

    /// The words for a file that is there but cannot be read (no permission, say).
    static let unreadableMessage = ConfigWriter.UnreadableError().localizedDescription

    /// The file is read and parses again: a syntax error or an unreadable file reported
    /// earlier no longer holds.
    func fileIsValid() {
        if error == ConfigWriter.SyntaxError.message || error == Self.unreadableMessage { problem = nil }
    }
}

/// What a model does when the app has loaded the file.
enum FileChange {
    case none
    /// Its part of the file changed elsewhere: show it.
    case reload
    /// Its part is as the model last read it, but the model's last save failed: save again, so
    /// the change the page shows is not lost.
    case retrySave
}

/// How a settings model follows the file: the part of it the model shows (`SyncedSlice`), the
/// values as last loaded or saved (only what changed since is written), the last save error,
/// and a reload skipped while the user was editing, which is done when the edit ends and
/// always before the next save, so that save never writes back a stale list.
///
/// A save that fails (the file has a syntax error, the disk is full) leaves the page showing a
/// change the file does not have. When the file is next loaded, the save is tried again if the
/// model's part of the file is still as the model read it; if that part changed meanwhile, the
/// file wins and the page reloads (retrying would write stale lists over the newer ones).
struct FileSync<Snapshot> {
    private var slice: SyncedSlice
    /// The values as last loaded or saved: a value never changed here is not written.
    private(set) var loaded: Snapshot?
    /// The file changed while the user was editing (recording a shortcut, typing a name).
    private(set) var reloadDeferred = false
    /// The last save failed: the page shows a change the file does not have.
    private(set) var unsaved = false
    let status = SaveStatus()

    init(_ slice: SyncedSlice) {
        self.slice = slice
    }

    /// The model showed `root`, its values being `snapshot`.
    mutating func didLoad(_ root: [String: Any], _ snapshot: Snapshot) {
        slice.record(root)
        loaded = snapshot
        reloadDeferred = false
        unsaved = false
    }

    /// The app loaded the file (it parses): what the model should do. A reload does not happen
    /// while `editing`: it then waits for `takeDeferredReload`.
    mutating func fileLoaded(_ root: [String: Any], editing: Bool) -> FileChange {
        status.fileIsValid()
        guard slice.changed(in: root) else {
            reloadDeferred = false
            return unsaved ? .retrySave : .none
        }
        if editing {
            reloadDeferred = true
            return .none
        }
        return .reload
    }

    /// An edit ends, or a save is about to start: the file to show first, if a reload was
    /// skipped meanwhile and the model's part still differs from it.
    mutating func takeDeferredReload() -> [String: Any]? {
        guard reloadDeferred else { return nil }
        reloadDeferred = false
        guard let root = ConfigWriter.readIfValid(), slice.changed(in: root) else { return nil }
        return root
    }

    /// Applies `change` to the file; once written, `snapshot` is what was saved. The error
    /// goes to `status`, and is returned.
    @discardableResult
    mutating func save(_ snapshot: Snapshot, _ change: (inout [String: Any]) -> Void) -> String? {
        let error = ConfigWriter.save(recording: &slice, change)
        didSave(snapshot, error: error)
        return error
    }

    /// The outcome of a save of `snapshot`: written (`error` nil), or not.
    mutating func didSave(_ snapshot: Snapshot, error: String?) {
        if error == nil { loaded = snapshot }
        unsaved = error != nil
        status.set(error)
    }
}

extension FileSync where Snapshot == Void {
    /// For a slice with no values of its own to compare.
    mutating func didLoad(_ root: [String: Any]) { didLoad(root, ()) }
}

/// A settings model that follows the file: `ConfigStore.didLoad` makes it reload when the part
/// of the file it shows changed, unless the user is in the middle of an edit. A model gives its
/// `FileSync`, how it reads the file (`load`) and how it writes its values (`save`); following
/// the file and saving a change are the same for all of them (the extension below).
protocol FileBackedModel: AnyObject {
    associatedtype Snapshot
    var sync: FileSync<Snapshot> { get set }
    /// Something is being edited (a shortcut recorded, a name typed, a slider moved): a reload
    /// now would undo it, so it waits for the edit to end.
    var isEditing: Bool { get }
    /// Shows `root`, the whole file, and tells `sync` (`didLoad`).
    func load(_ root: [String: Any])
    /// Writes what changed since the load, through `sync.save`.
    func save()
    /// A reload skipped while editing, done now (the default: `load` of the file as it is).
    func applyDeferredReload()
    /// A key press or click being recorded ends (another page is shown, the window is no
    /// longer the key one).
    func stopCapture()
    /// The window closes: captures end, pending edits are saved, nothing stays suspended.
    func close()
}

extension FileBackedModel {
    /// What keeps the model's pages from saving, for their notice.
    var saveStatus: SaveStatus { sync.status }

    var isEditing: Bool { false }

    /// The app loaded the file: show it if the model's part changed elsewhere, or save again a
    /// change that could not be written before (see `FileSync`).
    func reload(from root: [String: Any]) {
        switch sync.fileLoaded(root, editing: isEditing) {
        case .reload: load(root)
        case .retrySave: save()
        case .none: break
        }
    }

    func applyDeferredReload() {
        if let root = sync.takeDeferredReload() { load(root) }
    }

    /// A change made on the page: a reload skipped while editing comes first, so the save that
    /// follows writes the file's latest values with the change.
    func edit(_ change: () -> Void) {
        applyDeferredReload()
        change()
        save()
    }

    func stopCapture() {}
    func close() { stopCapture() }
}

/// Assigns only a change: every `@Published` assignment redraws the views that read it, equal or not.
func assignIfChanged<Value: Equatable>(_ value: Value, to property: inout Value) {
    if property != value { property = value }
}

/// Row ids across a reload: each new row takes the id of an old row with the same `key`
/// (each old id used once, in order), else a new one. SwiftUI then keeps the rows that did
/// not change, and a focused text field its focus.
func reusedIDs<Key: Hashable>(for keys: [Key], from old: [(key: Key, id: UUID)]) -> [UUID] {
    var available: [Key: [UUID]] = [:]
    for row in old { available[row.key, default: []].append(row.id) }
    return keys.map { key in
        guard var ids = available[key], !ids.isEmpty else { return UUID() }
        let id = ids.removeFirst()
        available[key] = ids
        return id
    }
}

extension Array where Element: Identifiable {
    /// Changes the element with `id`, if there is one.
    mutating func update(id: Element.ID, _ change: (inout Element) -> Void) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        change(&self[index])
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Writes `value` under `key` only when it differs from `old`, the value as loaded: an
    /// option the user never changed stays out of the file, or stays as it is written there.
    mutating func write<T: Equatable>(_ key: String, _ value: T, since old: T?) {
        if value != old { self[key] = value }
    }

    /// `write` for a list, as it goes in the file: an empty one is left out.
    mutating func writeList(_ key: String, _ list: [Any], since old: [Any]?) {
        guard listChanged(list, since: old) else { return }
        self[key] = list.isEmpty ? nil : list
    }
}

/// Whether `list` differs from `old`, the list as loaded (nil: nothing was loaded): the one
/// test of "write a list only once it changed" every page uses.
func listChanged(_ list: [Any], since old: [Any]?) -> Bool {
    guard let old else { return true }
    return !(list as NSArray).isEqual(to: old)
}
