import AppKit
import ApplicationServices

/// Scratchpad: windows kept out of the tiling and shown centered above the others on demand.
extension WindowManager {
    // MARK: - Scratchpad

    /// Shows or hides an app's scratchpad window, opening the app (or a window of it) first
    /// when needed; with no app, the windows sent to the scratchpad.
    func toggleScratchpad(app name: String?) {
        enterScope()
        defer { leaveScope() }
        guard running else { return }
        let focusedID = focused()?.id
        guard let name else {
            let pad = orderedWindows.filter(\.scratchpad)
            if let shown = pad.first(where: { $0.scratchpadShown && $0.id == focusedID }) {
                hideScratchpad(shown)
            } else if let shown = pad.first(where: \.scratchpadShown) {
                focus(shown)
            } else if let hidden = pad.first {
                showScratchpad(hidden)
            }
            return
        }
        guard let (bundleID, mine) = appWindows(of: name) else { return }
        if let window = mine.first(where: \.scratchpad) {
            if window.scratchpadShown, window.id == focusedID { hideScratchpad(window) } else { showScratchpad(window) }
        } else if let window = mine.first(where: { $0.id == focusedID }) ?? mine.first {
            // Already open in the tiling: it moves to the scratchpad.
            window.scratchpad = true
            showScratchpad(window)
        } else {
            // Not open, or no window: its next window is the scratchpad one.
            pendingScratchpad = pendingScratchpad.filter { $0.value > Date() }
            pendingScratchpad[bundleID] = Date().addingTimeInterval(30)
            AppLauncher.open(name)
        }
    }

    /// The focused window, or with an app that app's window, goes into the scratchpad (shown),
    /// or from it into the tiling of the workspace you are on. An app not open is opened.
    func moveToScratchpad(app name: String?) {
        enterScope()
        defer { leaveScope() }
        guard running else { return }
        guard let name else {
            if let window = focused() { toggleScratchpadTiling(window) }
            return
        }
        guard let (_, mine) = appWindows(of: name) else { return }
        let focusedID = focused()?.id
        if let window = mine.first(where: \.scratchpad) ?? mine.first(where: { $0.id == focusedID }) ?? mine.first {
            toggleScratchpadTiling(window)
        } else {
            AppLauncher.open(name)
        }
    }

    /// The tracked windows, in tiling order, of the app a scratchpad action names (a bundle id
    /// or an app name); nil, with a note for the debug report, when no such app is installed.
    private func appWindows(of name: String) -> (bundleID: String, windows: [ManagedWindow])? {
        guard let bundleID = AppLauncher.bundleID(for: name) else {
            note("scratchpad: app not found: \(name)")
            return nil
        }
        return (bundleID, orderedWindows.filter { $0.bundleID == bundleID })
    }

    private func toggleScratchpadTiling(_ window: ManagedWindow) {
        if window.scratchpad {
            window.scratchpad = false
            window.scratchpadShown = false
            window.hiddenFrame = nil
            window.workspace = focusedScreen().flatMap { displayed[$0.id] } ?? window.workspace
            log.debug("window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) back into workspace \(window.workspace)")
            retile()
            focus(window)
        } else {
            window.scratchpad = true
            showScratchpad(window)
            retile()
        }
    }

    func showScratchpad(_ window: ManagedWindow) {
        guard windows[window.id] === window, window.scratchpad else { return }
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard let screen = focusedScreen() ?? screens.first else { return }
        ignoreFocusChanges()
        let target = Self.scratchpadFrame(in: screen.visible, size: config.scratchpadSize)
        let frame = scratchpadFitted.flatMap { $0.target == target ? target.centered($0.size, rounded: true) : nil } ?? target
        let current = currentBounds()[window.id]
        log.debug("show scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) on display \(screen.id)")
        window.scratchpadShown = true
        window.hiddenFrame = nil
        setFrame(window, frame, from: current, screens: screens)
        // Apps that size in steps (terminals) or have a minimum size miss the exact size:
        // centered on what they took, and the other scratchpad windows take it too.
        let element = window.element
        let misses = { (size: CGSize) in abs(size.width - frame.width) > 1 || abs(size.height - frame.height) > 1 }
        writer.perform(window.pid, retryAfter: 0.1) { [weak self] isRetry in
            guard var size = AX.size(element) else { return false }
            // Coming from another display, some apps resize themselves a moment after the
            // move (a different scale): look again 0.1 s later (the app's queue is free
            // meanwhile) and ask once more before taking their size as their best.
            if misses(size) {
                if !isRetry { return true }
                AX.setSize(element, frame.size)
                size = AX.size(element) ?? size
            }
            guard let origin = AX.position(element) else { return false }
            if misses(size) {
                DispatchQueue.main.async { self?.scratchpadFitted = (target, size) }
            }
            let centered = target.centered(size, rounded: true)
            if abs(origin.x - centered.minX) > 1 || abs(origin.y - centered.minY) > 1 {
                AX.setPosition(element, centered.origin)
            }
            return false
        }
        // Where it is going, not the corner it was parked in (another display maybe).
        focus(window, at: frame)
        notifyWorkspace()
    }

    private func hideScratchpad(_ window: ManagedWindow) {
        enterScope()
        defer { leaveScope() }
        ignoreFocusChanges()
        window.scratchpadShown = false
        let screens = currentScreens()
        let frame = currentBounds()[window.id]
        if let frame { hide(window, from: frame, screens: screens) }
        log.debug("hide scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public))")
        // Back to what you were doing, on the display it was shown on: the pointer stays there.
        let here = frame.flatMap { screens.isEmpty ? nil : screens[screens.index(for: $0)].id } ?? activeDisplay
        if let workspace = here.flatMap({ displayed[$0] }) ?? screens.first.flatMap({ displayed[$0.id] }) {
            focusWindow(in: workspace)
        }
    }

    /// Centered in the visible area, `size` being fractions of it.
    static func scratchpadFrame(in visible: CGRect, size: CGSize) -> CGRect {
        let fitted = CGSize(width: (visible.width * size.width).rounded(), height: (visible.height * size.height).rounded())
        return visible.centered(fitted, rounded: true)
    }
}
