import Combine
import Foundation

/// State of the Shortcuts page: the window-management actions and their shortcuts, which are
/// ordinary entries of `keyboard.bindings`. Recording and saving go through the shared
/// `TilingModel`.
final class ShortcutsModel: ObservableObject {
    @Published private(set) var shortcuts: [TilingModel.Shortcut] = []

    /// The writer the four window pages share.
    weak var store: TilingModel?

    /// The shortcut of `action`, empty when it has none.
    func keys(for action: String) -> String {
        shortcuts.first { $0.action == action }?.keys ?? ""
    }

    /// Every shortcut of the page, for the duplicate check.
    var shortcutKeys: [String] { shortcuts.map(\.keys) }

    /// The keys recorded for `action`, when it is one of the page's (called inside the store's `edit`).
    func setKeys(_ keys: String, for action: String) {
        if let index = shortcuts.firstIndex(where: { $0.action == action }) { shortcuts[index].keys = keys }
    }

    /// Shows the bindings of the file: for each action, its last binding (the one that works).
    func load(_ bindings: [[String: Any]]) {
        assignIfChanged(TilingModel.shortcutActions.map { action in
            let keys = bindings.last { TilingModel.sameAction($0["action"] as? String ?? "", action) }?["keys"] as? String
            return TilingModel.Shortcut(action: action, keys: keys ?? "")
        }, to: &shortcuts)
    }
}
