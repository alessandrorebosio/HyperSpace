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
}

/// The last save of a model that failed, shown as a notice at the top of its pages. Its own
/// object, so an error that comes or goes redraws the notice only.
final class SaveStatus: ObservableObject {
    @Published private(set) var error: String?

    func set(_ error: String?) {
        assignIfChanged(error, to: &self.error)
    }

    /// The file parses again: a syntax error reported earlier no longer holds.
    func fileIsValid() {
        if error == ConfigWriter.SyntaxError.message { error = nil }
    }
}

/// How a settings model follows the file: the part of it the model shows (`SyncedSlice`), the
/// values as last loaded or saved (only what changed since is written), the last save error,
/// and a reload skipped while the user was editing, which is done when the edit ends and
/// always before the next save, so that save never writes back a stale list.
struct FileSync<Snapshot> {
    private var slice: SyncedSlice
    /// The values as last loaded or saved: a value never changed here is not written.
    private(set) var loaded: Snapshot?
    /// The file changed while the user was editing (recording a shortcut, typing a name).
    private(set) var reloadDeferred = false
    let status = SaveStatus()

    init(_ slice: SyncedSlice) {
        self.slice = slice
    }

    /// The model showed `root`, its values being `snapshot`.
    mutating func didLoad(_ root: [String: Any], _ snapshot: Snapshot) {
        slice.record(root)
        loaded = snapshot
        reloadDeferred = false
    }

    /// The app loaded the file: whether the model should show it. Not while `editing`: the
    /// reload then waits for `takeDeferredReload`.
    mutating func shouldReload(_ root: [String: Any], editing: Bool) -> Bool {
        status.fileIsValid()
        guard slice.changed(in: root) else {
            reloadDeferred = false
            return false
        }
        if editing {
            reloadDeferred = true
            return false
        }
        return true
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
        if error == nil { loaded = snapshot }
        status.set(error)
        return error
    }
}

extension FileSync where Snapshot == Void {
    mutating func didLoad(_ root: [String: Any]) { didLoad(root, ()) }

    @discardableResult
    mutating func save(_ change: (inout [String: Any]) -> Void) -> String? { save((), change) }
}

/// A settings model that follows the file: `ConfigStore.didLoad` makes it reload when the part
/// of the file it shows changed, unless the user is in the middle of an edit.
protocol FileBackedModel: AnyObject {
    func reload(from root: [String: Any])
    /// The last save error, for the page's notice.
    var saveStatus: SaveStatus { get }
    /// A key press or click being recorded ends (another page is shown).
    func stopCapture()
    /// The window closes: captures end, pending edits are saved, nothing stays suspended.
    func close()
}

extension FileBackedModel {
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
