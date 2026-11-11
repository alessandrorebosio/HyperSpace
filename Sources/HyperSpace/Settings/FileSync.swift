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

/// A settings model that follows the file: `ConfigStore.didLoad` makes it reload when the part
/// of the file it shows changed, unless the user is in the middle of an edit.
protocol FileBackedModel: AnyObject {
    func reload(from root: [String: Any])
}

extension Optional where Wrapped: Equatable {
    /// Assigns only a change: every `@Published` assignment redraws the views that read it.
    static func assignChange(_ value: Wrapped?, to property: inout Wrapped?) {
        if property != value { property = value }
    }
}
