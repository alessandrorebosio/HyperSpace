import CoreGraphics
import Foundation

/// The window server's list of windows (`CGWindowListCopyWindowInfo`), read in one place.
/// Titles are never asked for, so no Screen Recording permission is needed.
enum WindowList {
    struct Entry {
        let id: CGWindowID
        /// 0 for ordinary windows; menus, the Dock and overlays sit on higher layers.
        let layer: Int
        let bounds: CGRect
        let owner: String?
    }

    /// Every window (other Spaces, minimized), or with `onScreenOnly` those on screen on the
    /// current Space; the desktop is left out of the on-screen list.
    private static func entries(onScreenOnly: Bool) -> [Entry] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : .optionAll
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
            return Entry(id: id, layer: info[kCGWindowLayer as String] as? Int ?? -1, bounds: bounds ?? .null,
                         owner: info[kCGWindowOwnerName as String] as? String)
        }
    }

    /// Ordinary (layer 0) windows on screen on the current Space, front to back.
    static func onScreen() -> [Entry] {
        entries(onScreenOnly: true).filter { $0.layer == 0 && !$0.bounds.isNull }
    }

    /// The ids of every window that exists, on any Space.
    static func allIDs() -> Set<CGWindowID> {
        Set(entries(onScreenOnly: false).map(\.id))
    }
}
