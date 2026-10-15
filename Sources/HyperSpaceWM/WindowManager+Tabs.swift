import Foundation
import HyperSpaceCore

extension WindowManager {
    /// macOS native tabs (Finder, Safari, Terminal...) from the window server alone: every
    /// tab of a group has the group's frame and only the selected one is on screen. Among
    /// windows of the app on the same bounds, with one of them off screen, the new ones and
    /// the tiled ones hidden behind another tab join the group. Parked windows of other
    /// workspaces can share bounds without being tabs, so they're never folded; a new tab of
    /// a parked group still joins it. Tiled windows only (plus `new`): minimized ones are off
    /// screen too. One window server call, no AX.
    @discardableResult
    func reconcileTabs(_ pid: pid_t, new: Set<WindowID> = []) -> Bool {
        guard let model else { return false }
        let ids = records.compactMap { id, entry in
            entry.app.pid == pid && (new.contains(id) || tabs[id] != nil || model.windows[id] != nil) ? id : nil
        }.sorted()
        guard ids.count > 1 else { return false }
        let server = system.windowServer(ids)
        var buckets: [[WindowID]] = []
        for id in ids {
            guard let bounds = server[id]?.bounds else { continue }
            if let i = buckets.firstIndex(where: { server[$0[0]]!.bounds.isClose(to: bounds) }) {
                buckets[i].append(id)
            } else {
                buckets.append([id])
            }
        }
        var changed = false
        for bucket in buckets where bucket.count > 1 && bucket.contains(where: { !server[$0]!.onscreen }) {
            let joining = bucket.filter { id in
                new.contains(id) || (model.windows[id] != nil && !server[id]!.onscreen && parked[id] == nil)
            }
            guard !joining.isEmpty, let head = bucket.first(where: { model.windows[$0] != nil && !joining.contains($0) })
                ?? bucket.lazy.compactMap({ self.tabs[$0] }).first
                ?? joining.first(where: { model.windows[$0] != nil })
                ?? joining.first(where: { server[$0]!.onscreen }) ?? joining.first else { continue }
            for id in joining where id != head {
                if model.windows[id] != nil {
                    // Tiled as a window before its group was known: fold it, tabs included.
                    model.remove(id)
                    for (tab, owner) in tabs where owner == id { tabs[tab] = head }
                    shownTab[id] = nil
                    changed = true
                }
                tabs[id] = head
            }
            if let shown = bucket.first(where: { server[$0]!.onscreen && ($0 == head || tabs[$0] == head) }) {
                shownTab[head] = shown == head ? nil : shown
            }
        }
        return changed
    }
}
