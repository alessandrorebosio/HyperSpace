import AppKit
import ApplicationServices

/// The commands behind shortcuts: focus, swap, resize, float, accordion, layout, and moving the focus between displays.
extension WindowManager {
    // MARK: - Commands

    func focused() -> ManagedWindow? {
        if let scope, scope.focusedRead { return scope.focused }
        let window = readFocused()
        if scope != nil {
            scope?.focusedRead = true
            scope?.focused = window
        }
        return window
    }

    /// Asks the frontmost app for its focused window (a synchronous AX round trip).
    private func readFocused() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = AX.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute),
              let id = AX.windowID(element) else { return nil }
        return windows[id]
    }

    /// The display the user works on: the focused window's, else the one we last moved the
    /// focus to (an empty workspace has no window), else the one under the pointer.
    func focusedScreen(_ focusedWindow: ManagedWindow?? = nil) -> ScreenInfo? {
        let screens = currentScreens()
        guard !screens.isEmpty else { return nil }
        // On an empty workspace the window left behind may still look focused.
        if let id = heldDisplay, let screen = screens.first(where: { $0.id == id }) { return screen }
        if let window = focusedWindow ?? focused(), window.hiddenFrame == nil, display(showing: window.workspace) != nil,
           let frame = currentBounds()[window.id] {
            return screens[screens.index(for: frame)]
        }
        if let id = activeDisplay, let screen = screens.first(where: { $0.id == id }) { return screen }
        let pointer = AX.pointer
        return screens.first { $0.frame.contains(pointer) } ?? screens.first
    }

    /// Windows of the displayed workspaces that are on screen, with their frames.
    func visible(_ bounds: [CGWindowID: CGRect], tiledOnly: Bool = false) -> [(ManagedWindow, CGRect)] {
        let shown = Set(displayed.values)
        return windows.values.compactMap { window in
            guard shown.contains(window.workspace), window.hiddenFrame == nil, !(tiledOnly && window.isFloating) else { return nil }
            return bounds[window.id].map { (window, $0) }
        }
    }

    func focus(_ direction: Direction) {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let current = focused(), let origin = bounds[current.id] else { return }
        // Accordion: left and right go through the stack in order (the windows overlap, so
        // their centers say little); past either end, on to the next display.
        if let next = accordionNeighbor(of: current, direction, bounds) {
            focus(next)
            return
        }
        let candidates = visible(bounds).filter { $0.0.id != current.id }
        if let target = Layout.neighbor(of: origin, direction, among: candidates) { focus(target) }
    }

    /// The previous or next tiled window of an accordion, for left and right.
    private func accordionNeighbor(of window: ManagedWindow, _ direction: Direction, _ bounds: [CGWindowID: CGRect]) -> ManagedWindow? {
        let kind = layout(of: window.workspace)
        guard direction == .left || direction == .right, !window.isFloating, !window.scratchpad,
              inAccordion(window, layout: kind) else { return nil }
        if kind == .columns {
            return columns[window.workspace]?.accordionNeighbor(of: window.id, direction == .right ? 1 : -1)
                .flatMap { windows[$0] }.flatMap { bounds[$0.id] == nil ? nil : $0 }
        }
        let tiled = tiledWindows(in: window.workspace, bounds: bounds)
        guard let index = tiled.firstIndex(where: { $0 === window }) else { return nil }
        let next = index + (direction == .right ? 1 : -1)
        return tiled.indices.contains(next) ? tiled[next] : nil
    }

    /// Whether a tiled window is shown in an accordion: the accordion layout, a workspace
    /// stacked with `accordion`, or (columns) an accordion column.
    func inAccordion(_ window: ManagedWindow, layout kind: LayoutKind) -> Bool {
        switch kind {
        case .accordion: return true
        case .columns: return columns[window.workspace]?.isInAccordion(window.id) ?? false
        case .tall, .wide, .monocle: return accordionWorkspaces.contains(window.workspace)
        }
    }

    /// Stacks the focused window's workspace as an accordion, or unstacks it. In columns the
    /// windows become one accordion column: move a window left or right (`swap`) to take it
    /// out into a column of its own, up or down to reorder the stack. In tall, wide and monocle
    /// the whole workspace is stacked, and any move puts it back in its layout.
    func toggleAccordion() {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard running, let window = focused(), !window.isFloating, !window.scratchpad, bounds[window.id] != nil else { return }
        let workspace = window.workspace
        lastFocused[workspace] = window.id
        switch layout(of: workspace) {
        case .accordion:
            return
        case .columns:
            var layout = columns[workspace] ?? ColumnLayout()
            layout.sync(with: tiledWindows(in: workspace, bounds: bounds).map(\.id))
            let on = layout.toggleAccordion(around: window.id)
            columns[workspace] = layout
            log.debug("accordion \(on ? "on" : "off") in workspace \(workspace)")
        case .tall, .wide, .monocle:
            if accordionWorkspaces.remove(workspace) == nil { accordionWorkspaces.insert(workspace) }
        }
        retile()
        focus(window)
    }

    /// The layout of the display showing a workspace.
    func layout(of workspace: Int) -> LayoutKind {
        state(for: display(showing: workspace)).layout
    }

    func swap(_ direction: Direction) {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let current = focused(), !current.isFloating, let origin = bounds[current.id] else { return }
        if layout(of: current.workspace) == .columns, columns[current.workspace]?.locate(current.id) != nil {
            // Columns: stack, unstack and reorder (see ColumnLayout.move); new arrangement, even shares.
            columns[current.workspace]?.move(current.id, direction)
            current.weight = 1
            retile()
            return
        }
        if accordionWorkspaces.contains(current.workspace), layout(of: current.workspace) != .columns {
            // Stacked on top of tall, wide or monocle: a move puts the windows back in the layout.
            accordionWorkspaces.remove(current.workspace)
            retile()
            return
        }
        if let neighbor = accordionNeighbor(of: current, direction, bounds) {
            swapOrder(current.id, neighbor.id)
            Swift.swap(&current.weight, &neighbor.weight)
            retile()
            return
        }
        let candidates = visible(bounds, tiledOnly: true).filter { $0.0.id != current.id }
        guard let target = Layout.neighbor(of: origin, direction, among: candidates), let targetFrame = bounds[target.id] else { return }
        swapOrder(current.id, target.id)
        Swift.swap(&current.weight, &target.weight)
        Swift.swap(&current.workspace, &target.workspace)
        // Exchanging frames also carries the windows across displays.
        setFrame(current, targetFrame, from: origin)
        setFrame(target, origin, from: targetFrame)
        scheduleRetile()
    }

    func swapMaster() {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let current = focused(), !current.isFloating, bounds[current.id] != nil,
              let master = tiledWindows(in: current.workspace, bounds: bounds).first, master !== current else { return }
        swapOrder(current.id, master.id)
        scheduleRetile()
    }

    func swapOrder(_ a: CGWindowID, _ b: CGWindowID) {
        guard let i = order.firstIndex(of: a), let j = order.firstIndex(of: b) else { return }
        order.swapAt(i, j)
    }

    func setLayout(_ kind: LayoutKind) {
        updateActiveScreen { $0.layout = kind }
    }

    func adjustRatio(_ delta: CGFloat) {
        updateActiveScreen { $0.ratio = ($0.ratio + delta).clamped(to: TilingConfig.ratioRange) }
    }

    /// Grows or shrinks the focused window by `delta` points. Floating windows are
    /// resized directly; tiled ones move the master/stack split or change their share
    /// of the stack (or of the columns).
    func resizeFocused(width isWidth: Bool, by delta: CGFloat) {
        enterScope()
        defer { leaveScope() }
        let bounds = currentBounds()
        guard let window = focused(), let frame = bounds[window.id] else { return }
        if window.isFloating {
            var resized = frame
            if isWidth {
                resized.size.width = max(Self.minimumWindowSize.width, frame.width + delta)
            } else {
                resized.size.height = max(Self.minimumWindowSize.height, frame.height + delta)
            }
            setFrame(window, resized)
            return
        }
        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        let screen = screens[screens.index(for: frame)]
        let tiled = tiledWindows(in: window.workspace, bounds: bounds)
        guard let position = tiled.firstIndex(where: { $0 === window }), tiled.count > 1 else { return }
        let area = area(of: screen)
        var state = state(for: screen.id)

        switch state.layout {
        case .tall, .wide:
            let splitIsHorizontal = state.layout == .tall
            if isWidth == splitIsHorizontal {
                // Across the master/stack split: the master grows, a stack window grows by shrinking it.
                let change = delta / (splitIsHorizontal ? area.width : area.height)
                state.ratio = (state.ratio + (position == 0 ? change : -change)).clamped(to: TilingConfig.ratioRange)
                setState(state, for: screen.id)
            } else {
                // Along the stack; the master always spans the whole length.
                guard position > 0, tiled.count > 2 else { return }
                let stack = Array(tiled.dropFirst())
                window.weight = Self.weight(at: position - 1, of: stack.map(\.weight), growingBy: delta,
                                            length: splitIsHorizontal ? area.height : area.width, gap: config.gap)
            }
        case .columns:
            guard var layout = columns[window.workspace], let (c, r) = layout.locate(window.id) else { return }
            if isWidth {
                let weights = layout.columns.map(\.weight)
                guard weights.count > 1 else { return }
                layout.setColumnWeight(c, Self.weight(at: c, of: weights, growingBy: delta, length: area.width, gap: config.gap))
                columns[window.workspace] = layout
            } else {
                let stack = layout.columns[c].windows.compactMap { windows[$0] }
                guard stack.count > 1 else { return }
                window.weight = Self.weight(at: r, of: stack.map(\.weight), growingBy: delta, length: area.height, gap: config.gap)
            }
        case .monocle, .accordion:
            return
        }
        retile()
    }

    /// The new weight for item `index` so that it gains `delta` points along `length`,
    /// with the other items keeping their weights (and sharing the difference).
    static func weight(at index: Int, of weights: [CGFloat], growingBy delta: CGFloat, length: CGFloat, gap: CGFloat) -> CGFloat {
        let usable = length - gap * CGFloat(weights.count - 1)
        let total = weights.reduce(0, +)
        let others = total - weights[index]
        let minimum: CGFloat = 80
        let current = usable * weights[index] / total
        let target = min(usable - minimum * CGFloat(weights.count - 1), max(minimum, current + delta))
        return max(0.05, target * others / (usable - target))
    }

    func toggleFloat() {
        enterScope()
        defer { leaveScope() }
        guard let window = focused() else { return }
        window.isFloating.toggle()
        window.userOverride = true
        if window.isFloating { focus(window) }
        scheduleRetile()
    }

    /// Moves the focused workspace, windows and arrangement, to the next display, where it
    /// replaces the workspace shown there (which stays intact, just hidden). The display it
    /// leaves goes back to the last of its own workspaces it showed, or to none.
    func moveWorkspaceToNextDisplay() {
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard running, screens.count > 1, let source = focusedScreen(), let workspace = displayed[source.id],
              let sourceIndex = screens.firstIndex(where: { $0.id == source.id }) else { return }
        let target = screens[(sourceIndex + 1) % screens.count]
        ignoreFocusChanges()
        if let window = focused(), window.workspace == workspace { lastFocused[workspace] = window.id }

        homeOverride[workspace] = target.uuid
        showWorkspace(workspace, on: target.id)
        let remaining = (0..<workspaceCount).filter { $0 != workspace && home(of: $0, screens)?.id == source.id }
        let back = Self.workspaceLeftBehind(remaining: remaining, shownBefore: shownBefore[source.id])
        showWorkspace(back, on: source.id)
        log.debug("move workspace \(workspace) from display \(source.id) to \(target.id); display \(source.id) now shows \(back ?? -1)")
        carryFloating(windows.values.filter { $0.workspace == workspace }, screens: screens)
        retile()
        let focusedWindow = focusWindow(in: workspace)
        notifyWorkspace(focused: .some(focusedWindow))
    }

    /// What a display shows once its workspace moved away: the last of its own it showed, or
    /// its first, or nothing when no workspace lives there any more.
    static func workspaceLeftBehind(remaining: [Int], shownBefore: Int?) -> Int? {
        shownBefore.flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.first
    }

    /// Focuses the workspace shown on the next display.
    func focusNextDisplay() {
        enterScope()
        defer { leaveScope() }
        let screens = currentScreens()
        guard screens.count > 1, let current = focusedScreen(),
              let index = screens.firstIndex(where: { $0.id == current.id }) else { return }
        guard let workspace = displayed[screens[(index + 1) % screens.count].id] else { return notifyWorkspace() }
        let window = focusWindow(in: workspace)
        notifyWorkspace(focused: .some(window))
    }
}
