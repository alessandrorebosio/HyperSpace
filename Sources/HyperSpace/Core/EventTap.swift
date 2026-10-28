import AppKit
import CoreGraphics

/// One active CGEventTap shared by the keyboard and mouse mappers.
///
/// It runs on its own high-priority thread so that window-management work on the
/// main thread can never delay input. All tap state is confined to that thread:
/// config updates are handed over with `CFRunLoopPerformBlock`, so the hot path
/// takes no locks and does no allocation.
final class EventTap {
    /// Stamped on events we synthesize so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x4859_5045

    private let onAction: (Action) -> Void
    private let drag: DragController
    private var runLoop: CFRunLoop!

    // Tap-thread state.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mask: CGEventMask = 0
    private var config = TapConfig()
    private var hyperDown = false
    private var swallowedKeys = [Bool](repeating: false, count: 128)
    private var swallowedButtons = [Bool](repeating: false, count: 32)
    private var dragMode: DragMode?

    init(drag: DragController, onAction: @escaping (Action) -> Void) {
        self.drag = drag
        self.onAction = onAction

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A port keeps the run loop alive while no tap is installed.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "HyperSpace.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func apply(_ newConfig: TapConfig) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            config = newConfig
            hyperDown = false
            dragMode = nil
            for i in swallowedKeys.indices { swallowedKeys[i] = false }
            for i in swallowedButtons.indices { swallowedButtons[i] = false }
            let newMask = newConfig.eventMask
            if newMask != mask || (tap == nil && newMask != 0) { installTap(mask: newMask) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func installTap(mask newMask: CGEventMask) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        tap = nil
        source = nil
        mask = newMask
        guard newMask != 0 else { return }

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: newMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("cannot create event tap (Accessibility permission missing?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }

        switch type {
        case .keyDown, .keyUp:
            return handleKey(event, down: type == .keyDown) ? nil : pass
        case .otherMouseDown, .otherMouseUp:
            return handleButton(event, down: type == .otherMouseDown) ? nil : pass
        case .scrollWheel:
            reverseScrollIfNeeded(event)
            return pass
        case .leftMouseDown, .rightMouseDown:
            return beginDrag(event, mode: type == .leftMouseDown ? .move : .resize) ? nil : pass
        case .leftMouseDragged, .rightMouseDragged:
            guard dragMode != nil else { return pass }
            drag.update(event.location)
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard dragMode != nil else { return pass }
            dragMode = nil
            drag.end(event.location)
            return nil
        default:
            return pass
        }
    }

    private func modifiers(of event: CGEvent) -> Modifiers {
        var mods = Modifiers(event.flags)
        if hyperDown { mods.formUnion(.hyper) }
        return mods
    }

    /// Returns true when the event must be swallowed.
    private func handleKey(_ event: CGEvent, down: Bool) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let hyper = config.hyperKeyCode, code == hyper {
            hyperDown = down
            return true
        }
        guard code < 128 else { return false }

        if hyperDown {
            // Unbound hyper chords still reach apps as cmd+alt+ctrl+shift.
            event.flags.formUnion([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        }
        if down {
            let index = config.keyTable[TapConfig.slot(code, modifiers(of: event))]
            guard index >= 0 else { return false }
            swallowedKeys[code] = true
            dispatch(config.actions[Int(index)])
            return true
        }
        if swallowedKeys[code] {
            swallowedKeys[code] = false
            return true
        }
        return false
    }

    private func handleButton(_ event: CGEvent, down: Bool) -> Bool {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard button < 32 else { return false }
        if down {
            let index = config.buttonTable[TapConfig.slot(button, modifiers(of: event))]
            guard index >= 0 else { return false }
            swallowedButtons[button] = true
            dispatch(config.actions[Int(index)])
            return true
        }
        if swallowedButtons[button] {
            swallowedButtons[button] = false
            return true
        }
        return false
    }

    /// Reverses only discrete wheels: trackpads and Magic Mouse report continuous
    /// scrolling and keep the system "natural" direction.
    private func reverseScrollIfNeeded(_ event: CGEvent) {
        guard config.reverseScroll, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
    }

    private func beginDrag(_ event: CGEvent, mode: DragMode) -> Bool {
        guard let required = config.dragModifier, modifiers(of: event) == required else { return false }
        dragMode = mode
        drag.begin(mode, at: event.location)
        return true
    }

    private func dispatch(_ action: Action) {
        let onAction = onAction
        DispatchQueue.main.async { onAction(action) }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
