import Foundation
import HyperSpaceCore

/// `scratchpad <app-bundle-id>`: one window of the app, floating, summoned onto the focused
/// workspace (always centered, at the same size) and put away by the same key. Put away,
/// it waits in a corner like the windows of hidden workspaces, so it comes back at once.
extension WindowManager {
    /// Share of the display the scratchpad gets, centered.
    private static let scratchpadSize = 0.8

    func scratchpad(_ bundleID: String) throws(InvalidConfig) {
        guard let model else { return }
        let windows = records.compactMap { $0.value.app.bundleID == bundleID && model.windows[$0.key] != nil ? $0.key : nil }
        // Its scratchpad, else its most recent window, one not just made ordinary if it can.
        let candidates = windows.filter { !model.releasedScratchpads.contains($0) }
        guard let window = windows.first(where: model.scratchpads.contains)
            ?? model.mostRecent(of: candidates.isEmpty ? windows : candidates) else {
            // No window yet: the app is launched (or woken up, it opens one) and that one is it.
            guard system.open(bundleID: bundleID) else { throw InvalidConfig(message: "no app with bundle id '\(bundleID)'") }
            pendingScratchpad = (bundleID, .now + .seconds(15))
            return
        }
        summon(window)
    }

    /// Toggles the window as the scratchpad. When it shows, it's centered on the focused
    /// display at the scratchpad's size, wherever it was moved or resized before: apply()
    /// gives a parked window back this frame as it shows it.
    private func summon(_ window: WindowID) {
        guard let model, model.toggleScratchpad(window),
              let v = model.monitors.first(where: { $0.id == model.focusedMonitor })?.visible else { return }
        let size = CGSize(width: v.width * Self.scratchpadSize, height: v.height * Self.scratchpadSize)
        parked[window] = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    /// The first window of an app `scratchpad` opened becomes its scratchpad, after any rule.
    func adoptScratchpad(_ new: [WindowRecord], of app: WindowApp) {
        guard let pending = pendingScratchpad, pending.bundleID == app.bundleID, let model else { return }
        guard ContinuousClock.now < pending.until else {
            pendingScratchpad = nil
            return
        }
        guard let window = new.first(where: { model.windows[$0.id] != nil })?.id else { return }
        pendingScratchpad = nil
        summon(window)
        apply()
        focusNative()
    }
}
