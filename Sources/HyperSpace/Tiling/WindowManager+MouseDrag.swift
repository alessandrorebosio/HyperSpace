import AppKit
import ApplicationServices

/// Moving and resizing windows with the mouse: modifier + left drag moves, modifier + right drag resizes.
extension WindowManager {
    // MARK: - Mouse drag (modifier + left drag moves, modifier + right drag resizes)

    func beginDrag(_ mode: DragMode, at point: CGPoint) {
        guard let element = AX.window(at: point),
              let origin = AX.position(element), let size = AX.size(element) else { return }
        // Focus and moves go through the app's AX queue, in order, off the main thread.
        let pid = AX.pid(element)
        writer.perform(pid) { AX.focus(element, pid: pid) }
        dragGeneration += 1
        dragWriteInFlight = false
        dragPendingPoint = nil
        drag = DragSession(mode: mode, element: element, pid: pid, id: AX.windowID(element), start: point,
                           frame: CGRect(origin: origin, size: size))
    }

    func updateDrag(to point: CGPoint) {
        guard let drag else { return }
        // One write at a time: while the app is busy only the newest point waits.
        if dragWriteInFlight {
            dragPendingPoint = point
        } else {
            writeDrag(drag, to: point)
        }
    }

    private func writeDrag(_ session: DragSession, to point: CGPoint) {
        dragWriteInFlight = true
        let generation = dragGeneration
        let dx = point.x - session.start.x
        let dy = point.y - session.start.y
        let element = session.element
        let frame = session.frame
        let mode = session.mode
        writer.perform(session.pid) { [weak self] in
            switch mode {
            case .move:
                AX.setPosition(element, CGPoint(x: frame.minX + dx, y: frame.minY + dy))
            case .resize:
                let minimum = WindowManager.minimumWindowSize
                AX.setSize(element, CGSize(width: max(minimum.width, frame.width + dx), height: max(minimum.height, frame.height + dy)))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == dragGeneration else { return }
                dragWriteInFlight = false
                // The point that arrived meanwhile is written even if the button was released.
                if let next = dragPendingPoint {
                    dragPendingPoint = nil
                    writeDrag(session, to: next)
                }
            }
        }
    }

    func endDrag(at point: CGPoint) {
        enterScope()
        defer { leaveScope() }
        guard let session = drag else { return }
        drag = nil
        guard running, let id = session.id, let window = windows[id], !window.isFloating else { return }

        let bounds = currentBounds()
        switch session.mode {
        case .move:
            // Dropping a tiled window onto another one swaps them; dropping it on another
            // display moves it into the workspace shown there.
            if let target = visible(bounds, tiledOnly: true).first(where: { $0.0.id != id && $0.1.contains(point) }) {
                swapOrder(id, target.0.id)
                if window.workspace == target.0.workspace {
                    columns[window.workspace]?.swap(id, target.0.id)
                }
                window.workspace = target.0.workspace
            } else if let screen = currentScreens().first(where: { $0.frame.contains(point) }),
                      let workspace = displayed[screen.id] {
                window.workspace = workspace
            }
        case .resize:
            // Resizing a tiled window drags the master/stack split instead (tall and wide only).
            guard let frame = bounds[id], let screen = currentScreens().screen(for: frame) else { break }
            var state = state(for: screen.id)
            guard state.layout == .tall || state.layout == .wide else { break }
            let isMaster = tiledWindows(in: window.workspace, bounds: bounds).first === window
            let delta = state.layout == .tall
                ? (point.x - session.start.x) / screen.visible.width
                : (point.y - session.start.y) / screen.visible.height
            state.ratio = (state.ratio + (isMaster ? delta : -delta)).clamped(to: TilingConfig.ratioRange)
            setState(state, for: screen.id)
        }
        scheduleRetile()
    }
}
