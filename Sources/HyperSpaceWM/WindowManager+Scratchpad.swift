import Foundation
import HyperSpaceCore

/// `scratchpad [--new] <app-bundle-id>`: one window of the app, taken from its workspace and
/// summoned floating onto the focused one (always centered, at the same size), then put
/// back by the same key: an ordinary window of its workspace again. `--new` opens a new
/// window of the app for it.
extension WindowManager {
    /// Share of the display the scratchpad gets, centered.
    private static let scratchpadSize = 0.8

    func scratchpad(_ bundleID: String, new: Bool = false) throws(InvalidConfig) {
        guard let model else { return }
        let windows = records.compactMap { $0.value.app.bundleID == bundleID && model.windows[$0.key] != nil ? $0.key : nil }
        // `--new`: the window its ⌘N menu item opens, if it has one; else as without.
        if new, !windows.isEmpty, let app = records[windows[0]]?.app {
            pendingScratchpad = (bundleID, .now + .seconds(5), pressed: true)
            app.pressNewWindow { [weak self] pressed in
                guard let self, !pressed else { return }
                self.pendingScratchpad = nil
                try? self.scratchpad(bundleID)
                self.apply()
                self.focusNative()
            }
            return
        }
        // Its shown scratchpad, else its most recent window, one not just made ordinary if it can.
        let candidates = windows.filter { !model.releasedScratchpads.contains($0) }
        guard let window = model.mostRecent(of: windows.filter { model.scratchpadHomes[$0] != nil })
            ?? model.mostRecent(of: candidates.isEmpty ? windows : candidates) else {
            // No window yet: the app is launched (or woken up, it opens one) and that one is it.
            guard system.open(bundleID: bundleID) else { throw InvalidConfig(message: "no app with bundle id '\(bundleID)'") }
            pendingScratchpad = (bundleID, .now + .seconds(15), pressed: false)
            return
        }
        summon(window)
    }

    /// Toggles the window as the scratchpad. When it shows, it's centered on the focused
    /// display at the scratchpad's size, wherever it was moved or resized before: apply()
    /// gives a parked window back this frame as it shows it.
    private func summon(_ window: WindowID, home: String? = nil) {
        guard let model, model.toggleScratchpad(window, home: home) else { return }
        center(window)
    }

    /// Gives the shown scratchpad its centered frame on its workspace's display, the next
    /// time apply() runs.
    func center(_ window: WindowID) {
        guard let model, let monitor = model.workspace(of: window)?.monitor ?? Optional(model.focusedMonitor),
              let v = model.monitors.first(where: { $0.id == monitor })?.visible else { return }
        let size = CGSize(width: v.width * Self.scratchpadSize, height: v.height * Self.scratchpadSize)
        parked[window] = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    /// The first window of an app `scratchpad` opened becomes its scratchpad, after any rule,
    /// in place of the app's scratchpad shown so far. It has no workspace of its own: put
    /// away, it goes where a rule `placed` it, else where the app was last, else to the
    /// fallback workspace.
    func adoptScratchpad(_ new: [WindowRecord], of app: WindowApp, placed: [WindowID: String]) {
        guard let pending = pendingScratchpad, pending.bundleID == app.bundleID, let model else { return }
        guard ContinuousClock.now < pending.until else {
            pendingScratchpad = nil
            return
        }
        guard let window = new.first(where: { model.windows[$0.id] != nil && !(pending.pressed && $0.floating) })?.id else { return }
        pendingScratchpad = nil
        for (id, entry) in records where entry.app === app && id != window && model.scratchpadHomes[id] != nil { model.putAway(id) }
        summon(window, home: placed[window] ?? app.bundleID.flatMap { appWorkspaces[$0] } ?? settings.scratchpadFallbackWorkspace)
        apply()
        focusNative()
    }
}
