import AppKit

/// Parking: windows of workspaces not shown wait in a bottom corner of a display, nearly all
/// of them off-screen, and come back when their workspace does, on quit, and after a crash.
extension WindowManager {
    /// Parks a window in a bottom corner of its screen, nearly all of it off-screen.
    func hide(_ window: ManagedWindow, from frame: CGRect, screens: [ScreenInfo]) {
        guard window.hiddenFrame == nil, let screen = screens.screen(for: frame) else { return }
        window.hiddenFrame = frame
        park(window, size: frame.size, on: screen, screens)
    }

    /// Keeps a parked window parked: macOS moves windows of an unplugged display onto the
    /// remaining one, parked ones included, and they would stay in view. It goes back to the
    /// corner; a floating one whose display is gone restores where macOS put it.
    func keepHidden(_ window: ManagedWindow, bounds: [CGWindowID: CGRect], screens: [ScreenInfo]) {
        guard let saved = window.hiddenFrame, let frame = bounds[window.id],
              !Self.isParked(frame, on: screens),
              !window.movedByUsRecently,
              let screen = screens.screen(for: frame) else { return }
        if !screens.contains(where: { $0.frame.contains(saved.center) }) { window.hiddenFrame = frame }
        park(window, size: frame.size, on: screen, screens)
    }

    /// A window that must be out of sight: parked now if it is on screen, else kept parked.
    func parkOrKeepHidden(_ window: ManagedWindow, bounds: [CGWindowID: CGRect], screens: [ScreenInfo]) {
        if window.hiddenFrame == nil, let frame = bounds[window.id] {
            hide(window, from: frame, screens: screens)
        } else {
            keepHidden(window, bounds: bounds, screens: screens)
        }
    }

    private func park(_ window: ManagedWindow, size: CGSize, on screen: ScreenInfo, _ screens: [ScreenInfo]) {
        window.movedByUs = Date()
        let element = window.element
        let others = screens.filter { $0.id != screen.id }.map(\.frame)
        let point = Self.parkingPoint(size: size, on: screen.frame, others: others)
        axQueues.perform(window.pid) { [weak window] in
            AX.setPosition(element, point)
            // Counted from the write itself (see `setFrame`).
            DispatchQueue.main.async { window?.movedByUs = Date() }
        }
    }

    /// Where a parked window of `size` goes (its top-left corner): the bottom-right corner of
    /// its display, all of it off-screen but a point; the bottom-left one (the window then
    /// lies to the left of the display) when another display beyond the bottom-right corner
    /// would show more of it there. When another display shows it in both (a wider display
    /// below), a bottom corner of another display that no display sees, if there is one.
    /// Only bottom corners: macOS keeps windows below the menu bar.
    static func parkingPoint(size: CGSize, on screen: CGRect, others: [CGRect]) -> CGPoint {
        func corners(_ display: CGRect) -> (right: CGPoint, left: CGPoint) {
            (CGPoint(x: display.maxX - 1, y: display.maxY - 1), CGPoint(x: display.minX - size.width + 1, y: display.maxY - 1))
        }
        func seen(_ origin: CGPoint, by displays: [CGRect]) -> CGFloat {
            displays.reduce(0) { $0 + CGRect(origin: origin, size: size).intersection($1).area }
        }
        let (right, left) = corners(screen)
        let onRight = seen(right, by: others)
        guard onRight > 0 else { return right }
        let onLeft = seen(left, by: others)
        guard onLeft > 0 else { return left }
        for (index, other) in others.enumerated() {
            let rest = [screen] + others.enumerated().filter { $0.offset != index }.map(\.element)
            let (right, left) = corners(other)
            if let free = [right, left].first(where: { seen($0, by: rest) == 0 }) { return free }
        }
        return onLeft < onRight ? left : right
    }

    /// Whether a window shows at most a sliver on every screen (or none): parked, not in view.
    static func isParked(_ frame: CGRect, on screens: [ScreenInfo]) -> Bool {
        let seen = screens.map { frame.intersection($0.frame) }.filter { !$0.isNull }
        guard let best = seen.max(by: { $0.area < $1.area }) else { return true }
        return best.width <= 40 || best.height <= 40 || best.area < 0.1 * frame.area
    }

    /// Whether no display shows any of `frame`: not even the point a parked window leaves in view.
    static func isOutOfSight(_ frame: CGRect, on screens: [ScreenInfo]) -> Bool {
        !screens.contains { $0.frame.intersects(frame) }
    }

    /// A floating window returns to its frame, on the display now showing its workspace;
    /// tiled ones are placed by the retile.
    /// `current` is where it is now, when known: one that kept its size is only moved back.
    func restore(_ window: ManagedWindow, on screen: ScreenInfo, _ screens: [ScreenInfo], from current: CGRect? = nil) {
        guard let frame = window.hiddenFrame else { return }
        setFrame(window, Self.place(frame, on: screen, screens), from: current, screens: screens)
        window.hiddenFrame = nil
    }

    /// `frame` on `screen`: as it is when already there, else moved from the display it is on
    /// keeping its position and size as shares of the visible area; centered when no display
    /// shows it at all (its display is gone, or left out while it shows nothing).
    static func place(_ frame: CGRect, on screen: ScreenInfo, _ screens: [ScreenInfo]) -> CGRect {
        guard !isOutOfSight(frame, on: screens) else { return screen.centered(frame.size) }
        guard let from = screens.screen(for: frame) else { return frame }
        return from.id == screen.id ? frame : from.relocate(frame, to: screen)
    }

    /// Floating windows of `workspaces` on screen but on another display than the one showing
    /// their workspace (it was just moved, or the window was): carried over, proportionally.
    func carryFloating(_ members: [ManagedWindow], screens: [ScreenInfo]) {
        let bounds = currentBounds()
        for window in members where window.isFloating && isMember(window, of: window.workspace) && window.hiddenFrame == nil {
            guard let frame = bounds[window.id], let id = display(showing: window.workspace),
                  let screen = screens.first(id: id) else { continue }
            let target = Self.place(frame, on: screen, screens)
            if !target.isClose(to: frame, tolerance: Self.looseTolerance) { setFrame(window, target, from: frame, screens: screens) }
        }
    }

    /// Puts every parked window back where it was. On quit (`waitUntilDone`) the writes are
    /// waited for (up to 1.5 s), so the windows really come back before the app exits; when
    /// tiling is merely turned off they go through the apps' queues without blocking.
    func restoreHiddenWindows(waitUntilDone: Bool = true) {
        // Where each is now: parking only moved it, so one that kept its size is only moved back.
        let bounds = currentBounds()
        let screens = currentScreens()
        for window in windows.values {
            guard let frame = window.hiddenFrame else { continue }
            setFrame(window, frame, from: bounds[window.id], screens: screens)
            window.hiddenFrame = nil
        }
        if waitUntilDone { axQueues.flush(timeout: 1.5) }
    }

    /// After a crash windows can be left parked off-screen: bring them back. Most were
    /// already taken for parked when found (`track`: they come back with their workspace);
    /// this is for the ones AX gave no frame for then.
    func rescueStrandedWindows() {
        let screens = currentScreens()
        guard let main = screens.first else { return }
        for (id, frame) in currentBounds() {
            guard let window = windows[id], window.hiddenFrame == nil, Self.isParked(frame, on: screens) else { continue }
            setFrame(window, main.centered(frame.size))
        }
    }
}
