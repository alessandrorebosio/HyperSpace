import AppKit

/// Moving and resizing windows with the mouse: modifier + left drag moves, modifier + right drag resizes.
extension WindowManager {
    // MARK: - Mouse drag (modifier + left drag moves, modifier + right drag resizes)

    /// The window under the pointer is looked up off the main thread (an app slow to answer
    /// must not hold up the shortcuts); the points that arrive meanwhile wait, the latest only.
    func beginDrag(_ mode: DragMode, at point: CGPoint) {
        dragState.generation += 1
        let generation = dragState.generation
        dragState.session = nil
        dragState.writeInFlight = false
        dragState.pendingPoint = nil
        dragState.endedEarly = nil
        dragState.starting = true
        dragLookup.async { [weak self] in
            let session = AX.window(at: point).flatMap { element -> DragSession? in
                guard let frame = AX.frame(element) else { return nil }
                return DragSession(mode: mode, element: element, pid: AX.pid(element), id: AX.windowID(element),
                                   start: point, frame: frame)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == dragState.generation, dragState.starting else { return }
                dragState.starting = false
                guard let session else {
                    dragState.pendingPoint = nil
                    dragState.endedEarly = nil
                    scheduleRetile()
                    return
                }
                // Focus and moves go through the app's AX queue, in order, off the main thread.
                axQueues.perform(session.pid) { AX.focus(session.element, pid: session.pid) }
                dragState.session = session
                if let pending = dragState.pendingPoint {
                    dragState.pendingPoint = nil
                    writeDrag(session, to: pending)
                }
                if let end = dragState.endedEarly {
                    dragState.endedEarly = nil
                    endDrag(at: end)
                }
            }
        }
    }

    func updateDrag(to point: CGPoint) {
        guard let drag = dragState.session else {
            if dragState.starting { dragState.pendingPoint = point }
            return
        }
        // One write at a time: while the app is busy only the newest point waits.
        if dragState.writeInFlight {
            dragState.pendingPoint = point
        } else {
            writeDrag(drag, to: point)
        }
    }

    private func writeDrag(_ session: DragSession, to point: CGPoint) {
        dragState.writeInFlight = true
        let generation = dragState.generation
        let dx = point.x - session.start.x
        let dy = point.y - session.start.y
        let element = session.element
        let frame = session.frame
        let mode = session.mode
        axQueues.perform(session.pid) { [weak self] in
            switch mode {
            case .move:
                AX.setPosition(element, CGPoint(x: frame.minX + dx, y: frame.minY + dy))
            case .resize:
                let minimum = WindowManager.minimumWindowSize
                AX.setSize(element, CGSize(width: max(minimum.width, frame.width + dx), height: max(minimum.height, frame.height + dy)))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == dragState.generation else { return }
                dragState.writeInFlight = false
                // The point that arrived meanwhile is written even if the button was released.
                if let next = dragState.pendingPoint {
                    dragState.pendingPoint = nil
                    writeDrag(session, to: next)
                }
            }
        }
    }

    func endDrag(at point: CGPoint) {
        if dragState.session == nil, dragState.starting {
            dragState.endedEarly = point
            return
        }
        scoped {
            guard let session = dragState.session else { return }
            dragState.session = nil
            // Whatever was dragged: the retiles asked for meanwhile were held back.
            defer { scheduleRetile() }
            // Floating and scratchpad windows stay where they are dropped.
            guard running, let id = session.id, let window = windows[id], takesTile(window) else { return }

            let bounds = currentBounds()
            switch session.mode {
            case .move:
                // Dropping a tiled window onto another one swaps them (as `swap` does, across
                // displays too); dropping it on another display moves it into the workspace
                // shown there.
                if let target = visible(bounds, tiledOnly: true).first(where: { $0.0.id != id && $0.1.contains(point) }) {
                    exchange(window, target.0)
                } else if let screen = currentScreens().first(where: { $0.frame.contains(point) }),
                          let workspace = displayed[screen.id], workspace != window.workspace {
                    setWorkspace(workspace, of: window)
                }
            case .resize:
                // Resizing a tiled window drags the master/stack split instead (tall and wide only).
                guard let frame = bounds[id], let screen = currentScreens().screen(for: frame) else { break }
                var state = state(for: screen.id)
                guard state.layout == .tall || state.layout == .wide else { break }
                let isMaster = tiledWindows(in: window.workspace, bounds: bounds).first === window
                // Shares of the layout's area, as the resize shortcut counts them.
                let area = area(of: screen)
                let dragged = state.layout == .tall ? point.x - session.start.x : point.y - session.start.y
                let delta = Self.ratioShare(of: dragged, in: area, layout: state.layout)
                state.adjustRatio(by: isMaster ? delta : -delta)
                setState(state, for: screen.id)
            }
        }
    }
}
