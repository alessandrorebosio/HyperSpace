import AppKit

/// Scratchpad: windows kept out of the tiling and shown centered above the others on demand.
extension WindowManager {
    // MARK: - Scratchpad

    /// Shows or hides an app's scratchpad window, opening the app (or a window of it) first
    /// when needed; with no app, the windows sent to the scratchpad.
    func toggleScratchpad(app name: String?) {
        scoped {
            guard running else { return }
            let focusedID = focused()?.id
            guard let name else {
                let pad = orderedWindows.filter(\.scratchpad)
                if let shown = pad.first(where: { $0.scratchpadShown && $0.id == focusedID }) {
                    hideScratchpad([shown])
                } else if let shown = pad.first(where: \.scratchpadShown) {
                    focus(shown)
                } else if let hidden = pad.first {
                    showScratchpad(hidden)
                }
                return
            }
            guard let (bundleID, mine) = appWindows(of: name) else { return }
            let pad = mine.filter(\.scratchpad)
            if !pad.isEmpty {
                // All of the app's scratchpad windows (it may have opened more from there) come and
                // go together; the one you worked in last ends up in front.
                let shown = pad.filter(\.scratchpadShown)
                if shown.contains(where: { $0.id == focusedID }) { hideScratchpad(shown) } else { showScratchpad(pad) }
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
    }

    /// The focused window, or with an app that app's window, goes into the scratchpad (shown),
    /// or from it into the tiling of the workspace you are on. An app not open is opened.
    func moveToScratchpad(app name: String?) {
        scoped {
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
            window.workspace = focusedWorkspace ?? window.workspace
            log.debug("window \(window.id) (\(window.bundleID ?? "?", privacy: .public)) back into workspace \(window.workspace)")
            retile()
            focus(window)
        } else {
            window.scratchpad = true
            showScratchpad(window)
            retile()
        }
    }

    /// Shows several scratchpad windows, the one focused last on top.
    func showScratchpad(_ windows: [ManagedWindow]) {
        let sorted = windows.sorted { $0.focusedAt < $1.focusedAt }
        for (index, window) in sorted.enumerated() { showScratchpad(window, focus: index == sorted.count - 1) }
    }

    func showScratchpad(_ window: ManagedWindow, focus takesFocus: Bool = true) {
        guard windows[window.id] === window, window.scratchpad else { return }
        scoped {
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
            let misses = { (size: CGSize) in !size.isClose(to: frame.size, tolerance: 1) }
            axQueues.perform(window.pid, retryAfter: 0.1) { [weak self] isRetry in
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
                if !origin.isClose(to: centered.origin, tolerance: 1) {
                    AX.setPosition(element, centered.origin)
                }
                return false
            }
            // Where it is going, not the corner it was parked in (another display maybe).
            if takesFocus { focus(window, at: frame) }
            // Its dialogs come back with it (see `retile`).
            if !dialogWindows(of: window).isEmpty { scheduleRetile() }
            notifyWorkspace()
        }
    }

    private func hideScratchpad(_ pad: [ManagedWindow]) {
        scoped {
            ignoreFocusChanges()
            let screens = currentScreens()
            let frame = parkScratchpad(pad, screens: screens, bounds: currentBounds())
            // Back to what you were doing, on the display it was shown on: the pointer stays there.
            let here = frame.flatMap { screens.screen(for: $0)?.id } ?? activeDisplay
            if let workspace = here.flatMap({ displayed[$0] }) ?? screens.first.flatMap({ displayed[$0.id] }) {
                focusWindow(in: workspace)
            }
        }
    }

    /// Parks scratchpad windows and their dialogs without touching the focus; returns the
    /// frame of the first one that was on screen (to know which display it was on).
    @discardableResult
    func parkScratchpad(_ pad: [ManagedWindow], screens: [ScreenInfo], bounds: [CGWindowID: CGRect]) -> CGRect? {
        var frame: CGRect?
        for window in pad {
            window.scratchpadShown = false
            if let shown = bounds[window.id] {
                hide(window, from: shown, screens: screens)
                frame = frame ?? shown
            }
            log.debug("hide scratchpad window \(window.id) (\(window.bundleID ?? "?", privacy: .public))")
        }
        // Its dialogs go with it.
        for dialog in pad.flatMap(dialogWindows) where dialog.hiddenFrame == nil {
            guard let shown = bounds[dialog.id] else { continue }
            hide(dialog, from: shown, screens: screens)
        }
        return frame
    }

    /// Centered in the visible area, `size` being fractions of it.
    static func scratchpadFrame(in visible: CGRect, size: CGSize) -> CGRect {
        let fitted = CGSize(width: (visible.width * size.width).rounded(), height: (visible.height * size.height).rounded())
        return visible.centered(fitted, rounded: true)
    }
}
