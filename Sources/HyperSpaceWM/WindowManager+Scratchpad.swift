import Foundation
import HyperSpaceCore

/// `scratchpad <app-bundle-id>`: one window of the app, floating, summoned onto the focused
/// workspace and put away by the same key. Put away, it waits in a corner like the windows
/// of hidden workspaces, so it comes back at once.
extension WindowManager {
    /// Share of the display a new scratchpad gets, centered.
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

    /// Toggles the window as the scratchpad, placed on the focused display when it shows.
    private func summon(_ window: WindowID) {
        guard let model else { return }
        guard model.toggleScratchpad(window), let monitor = model.monitors.first(where: { $0.id == model.focusedMonitor }) else { return }
        let isNew = placedScratchpads.insert(window).inserted
        // A new scratchpad, or one that was on another display: centered on this one. apply()
        // gives a parked window back this frame as it shows it.
        let v = monitor.visible
        guard let frame = parked[window] ?? frames[window],
              isNew || !v.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
        let size = isNew ? CGSize(width: v.width * Self.scratchpadSize, height: v.height * Self.scratchpadSize)
            : CGSize(width: min(frame.width, v.width), height: min(frame.height, v.height))
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
