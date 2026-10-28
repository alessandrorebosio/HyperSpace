import CoreGraphics
import Foundation
import os

enum DragMode {
    case move, resize
}

/// Bridges modifier+drag from the event tap thread to the window manager.
///
/// Drag events arrive at the mouse's report rate (up to 1000 Hz on gaming mice);
/// we keep only the latest position and schedule at most one main-thread update
/// at a time, so a slow app never builds up a backlog of AX calls.
final class DragController {
    private struct Pending {
        var point: CGPoint?
        var scheduled = false
    }

    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private unowned let windowManager: WindowManager

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    func begin(_ mode: DragMode, at point: CGPoint) {
        DispatchQueue.main.async { [self] in windowManager.beginDrag(mode, at: point) }
    }

    func update(_ point: CGPoint) {
        let schedule = pending.withLockUnchecked { state -> Bool in
            state.point = point
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let latest = pending.withLockUnchecked { state -> CGPoint? in
                state.scheduled = false
                defer { state.point = nil }
                return state.point
            }
            if let latest { windowManager.updateDrag(to: latest) }
        }
    }

    func end(_ point: CGPoint) {
        DispatchQueue.main.async { [self] in windowManager.endDrag(at: point) }
    }
}
