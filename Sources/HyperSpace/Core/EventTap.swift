import AppKit

/// One active CGEventTap shared by the keyboard and mouse mappers.
///
/// It runs on its own high-priority thread so that window-management work on the
/// main thread can never delay input. All tap state is confined to that thread:
/// config updates are handed over with `CFRunLoopPerformBlock`, so the hot path reads
/// plain arrays and takes no locks of its own (the one allocation is the CGEvent a carrier posts).
final class EventTap {
    /// Stamped on events we synthesize so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x4859_5045
    /// Posted on the main thread when the keyboard is locked or unlocked.
    static let keyboardLockDidChange = Notification.Name("HyperSpaceKeyboardLockDidChange")
    /// NX_SYSDEFINED: media, volume and brightness keys.
    private static let systemDefined = CGEventType(rawValue: 14)!

    /// Every key is ignored (e.g. to clean the keyboard); unlocked with the mouse. Main thread.
    private(set) var isKeyboardLocked = false
    /// When the lock lifts by itself, if it does. Main thread.
    private(set) var keyboardUnlocksAt: Date?
    private var unlockTimer: Timer?
    /// Main thread: the config last asked for, and what was last handed to the tap thread
    /// (carrier keys translated to the keyboard layout in use).
    private var requestedConfig: TapConfig?
    private var pushedConfig: TapConfig?
    private var layoutObserver: NSObjectProtocol?

    private let onAction: (Action) -> Void
    /// The workspace overview: shown while its key is held (true), hidden on release (false).
    private let onOverview: (Bool) -> Void
    private let drag: DragController
    private var runLoop: CFRunLoop!

    // Tap-thread state.
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mask: CGEventMask = 0
    /// Keys, buttons, held combinations and the overview key: the decisions, kept pure.
    private var state = TapState()
    private var config: TapConfig { state.config }
    private var dragMode: DragMode?
    private var keyboardLocked = false
    /// Where the pointer is held while a trackpad edge slider is in progress.
    private var heldPointer: CGPoint?

    init(drag: DragController, onAction: @escaping (Action) -> Void, onOverview: @escaping (Bool) -> Void) {
        self.drag = drag
        self.onAction = onAction
        self.onOverview = onOverview

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
        // A carrier that types a symbol follows the layout: translated again when it changes.
        layoutObserver = NotificationCenter.default.addObserver(
            forName: KeyboardLayout.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.pushConfig() }
    }

    deinit {
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
    }

    /// Runs a block on the tap thread, which owns all tap state.
    private func onTapThread(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func apply(_ newConfig: TapConfig) {
        requestedConfig = newConfig
        pushConfig()
    }

    /// Hands the tap thread the requested config, with the keys of combinations translated to
    /// the current keyboard layout here, on the main thread (the tap thread never asks the
    /// input sources). Nothing happens when it is what the tap already has.
    private func pushConfig() {
        guard let requested = requestedConfig else { return }
        let translated = requested.translated { KeyboardLayout.keyCode(for: $0) }
        guard translated != pushedConfig else { return }
        pushedConfig = translated
        onTapThread { [self] in
            if state.setConfig(translated) { closeOverview() }
            cancelDrag()
            heldPointer = nil
            updateMask()
        }
    }

    /// Tap thread: the key holding the overview went up (or is forgotten): it closes.
    private func closeOverview() {
        let onOverview = onOverview
        DispatchQueue.main.async { onOverview(false) }
    }

    /// Tap thread: a modifier-drag whose mouse-up will not be seen (a new config, a tap that
    /// timed out) ends where the pointer is, so the window manager does not wait for it.
    private func cancelDrag() {
        guard dragMode != nil else { return }
        dragMode = nil
        drag.cancel()
    }

    /// Locks for `KeyboardLock.minutes` (or until unlocked when 0), or unlocks.
    func setKeyboardLocked(_ locked: Bool) {
        guard locked != isKeyboardLocked else { return }
        // Without the permission there is no tap to ignore the keys: a lock would only claim to be on.
        if locked, !Permissions.isTrusted(prompt: false) {
            log.error("keyboard not locked: Accessibility permission missing")
            NSSound.beep()
            return
        }
        isKeyboardLocked = locked
        unlockTimer?.invalidate()
        unlockTimer = nil
        keyboardUnlocksAt = nil
        if locked, KeyboardLock.minutes > 0 {
            let duration = TimeInterval(KeyboardLock.minutes * 60)
            keyboardUnlocksAt = Date().addingTimeInterval(duration)
            unlockTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                self?.setKeyboardLocked(false)
            }
        }
        log.info("keyboard \(locked ? "locked" : "unlocked", privacy: .public)")
        onTapThread { [self] in
            keyboardLocked = locked
            if state.resetKeys() { closeOverview() }
            updateMask()
        }
        NotificationCenter.default.post(name: Self.keyboardLockDidChange, object: self)
    }

    /// The events the config needs, plus every keyboard event while locked.
    private func updateMask() {
        var newMask = config.eventMask
        if keyboardLocked {
            for type in [CGEventType.keyDown, .keyUp, .flagsChanged, Self.systemDefined] {
                newMask |= CGEventMask(1) << type.rawValue
            }
        }
        if newMask != mask || (tap == nil && newMask != 0) { installTap(mask: newMask) }
    }

    /// Holds the pointer where it is, or lets it go (the trackpad edge sliders). Safe to call
    /// from any thread: the multitouch thread calls it, so the hold starts without a detour
    /// through the main thread.
    func setPointerHeld(_ held: Bool) {
        onTapThread { [self] in
            guard config.holdsPointer || !held else { return }
            heldPointer = held ? (heldPointer ?? Pointer.eventLocation) : nil
        }
    }

    func setButtonsSuspended(_ suspended: Bool) {
        onTapThread { [self] in state.setButtonsSuspended(suspended) }
    }

    func setKeyBindingsSuspended(_ suspended: Bool) {
        onTapThread { [self] in
            if state.setKeyBindingsSuspended(suspended) { closeOverview() }
        }
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
            // Events were missed meanwhile, the mouse-up of a drag among them perhaps.
            cancelDrag()
            return pass
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        if keyboardLocked {
            switch type {
            case .keyDown, .keyUp, .flagsChanged: return nil
            case Self.systemDefined:
                // Subtype 8 is the media/volume/brightness keys; other subtypes come from the mouse.
                return NSEvent(cgEvent: event)?.subtype.rawValue == 8 ? nil : pass
            default: break
            }
        }
        if config.suppressCapsLock, event.flags.contains(.maskAlphaShift) {
            // A remapped caps lock must not engage caps lock: drop the flag right away
            // and switch the lock state off (the reset arrives as another flagsChanged).
            event.flags.remove(.maskAlphaShift)
            if type == .flagsChanged { DispatchQueue.main.async { CapsLock.turnOff() } }
        }
        if !state.heldModifiers.isEmpty {
            // Unbound chords still reach apps with the combination's modifiers.
            event.flags.formUnion(state.heldModifiers.cgFlags)
        }

        switch type {
        case .keyDown, .keyUp:
            let decision = state.key(code: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                     modifiers: Modifiers(event.flags), down: type == .keyDown,
                                     isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            return perform(decision) ? nil : pass
        case .otherMouseDown, .otherMouseUp:
            let decision = state.button(Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                                        modifiers: Modifiers(event.flags), down: type == .otherMouseDown)
            return perform(decision) ? nil : pass
        case .scrollWheel:
            reverseScrollIfNeeded(event)
            return pass
        case .mouseMoved:
            guard let held = heldPointer else { return pass }
            // Dropped; and should the pointer have moved anyway, it goes back.
            if !event.location.isClose(to: held, tolerance: 0.5) { Pointer.warp(to: held) }
            return nil
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

    /// Tap thread: carries out a decision; true when the event is swallowed.
    private func perform(_ decision: TapState.Decision) -> Bool {
        switch decision {
        case .pass:
            return false
        case .swallow:
            return true
        case .run(let action):
            dispatch(action)
            return true
        case .overview(let shown):
            let onOverview = onOverview
            DispatchQueue.main.async { onOverview(shown) }
            return true
        case .postKey(let keyCode, let modifiers, let down):
            KeyEmitter.post(keyCode: keyCode, flags: modifiers.cgFlags, down: down)
            return true
        }
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
        guard let required = config.dragModifier, Modifiers(event.flags) == required else { return false }
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
