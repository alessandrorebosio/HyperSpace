import AppKit

/// The one active CGEventTap: key bindings, combination carriers, mouse buttons, reversed
/// scrolling, modifier-drag, the keyboard lock and the trackpad's pointer and click holds.
///
/// It runs on its own high-priority thread so that window-management work on the
/// main thread can never delay input. All tap state is confined to that thread:
/// config updates are handed over with `CFRunLoopPerformBlock`, so the hot path reads
/// plain arrays and takes no locks of its own. It allocates only to post an event (a
/// carrier's key) and to hand an action or the overview to the main thread.
///
/// Created once and kept for the app's lifetime: the tap thread and the C callback hold it
/// unretained, so it is never released.
final class EventTap {
    /// Stamped on events we synthesize so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x4859_5045
    /// Posted on the main thread when the keyboard is locked or unlocked.
    static let keyboardLockDidChange = Notification.Name("HyperSpace.keyboardLockDidChange")
    /// Posted on the main thread when `isTapUnavailable` changes.
    static let tapAvailabilityDidChange = Notification.Name("HyperSpace.eventTapAvailabilityDidChange")

    /// Every key is ignored (e.g. to clean the keyboard); unlocked with the mouse. Main thread.
    private(set) var isKeyboardLocked = false
    /// When the lock lifts by itself, if it does. Main thread.
    private(set) var keyboardUnlocksAt: Date?
    private var unlockTimer: Timer?
    /// The system refused the tap the config needs (a stale Accessibility grant after a rebuild,
    /// say): no shortcut, button or lock works until it is made, which is tried again every
    /// `tapRetryInterval`. Main thread.
    private(set) var isTapUnavailable = false
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
    /// A modifier-drag in progress: its mode says its button (left moves, right resizes).
    private struct Drag {
        let mode: DragMode
        /// The other of left and right went down during the drag: swallowed, and so its up.
        var otherButtonDown = false
    }
    private var activeDrag: Drag?
    private var keyboardLocked = false
    /// The last attempt to make the tap failed, and whether another one is already scheduled.
    private var tapFailed = false
    private var tapRetryScheduled = false
    /// Where the pointer is held while a trackpad edge slider is in progress, until
    /// `heldPointerUntil` (uptime nanoseconds) unless the hold is renewed: a trackpad that
    /// goes away with a finger on it must not leave the pointer stuck.
    private var heldPointer: CGPoint?
    private var heldPointerUntil: UInt64 = 0
    /// A finger is down in a trackpad corner with an action: clicks are dropped (the ones tap
    /// to click makes for a tap there) until `cornerClicksHeldUntil` at the latest, and until
    /// `cornerClicksUntil` after the lift (uptime nanoseconds, both).
    private var cornerClicksHeld = false
    private var cornerClicksHeldUntil: UInt64 = 0
    private var cornerClicksUntil: UInt64 = 0
    /// The left (0) and right (1) button downs dropped that way: their ups are dropped too.
    private var droppedClicks = (false, false)
    /// How long clicks are still dropped after a corner tap's finger is lifted: tap to click
    /// posts the click on the lift, as a double click on the second tap.
    private static let cornerClickGrace: UInt64 = 400_000_000
    /// How long a hold lasts without news from the trackpad. The pointer's is renewed several
    /// times within it while a slider goes on (`EdgeSliders`); the clicks' never is, a corner
    /// tap being much shorter.
    private static let holdTimeout: UInt64 = 500_000_000
    /// How often a tap the system refused is tried again.
    private static let tapRetryInterval: TimeInterval = 5

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

    // No deinit: the instance lives as long as the app (see above). Releasing it would leave
    // the tap's refcon and the tap thread's `unowned self` dangling, and its tap state
    // belongs to the tap thread, so the main thread could not tear it down safely anyway.

    /// Tap thread: hands `value` to a main-thread handler.
    private static func onMain<Value>(_ handler: @escaping (Value) -> Void, _ value: Value) {
        DispatchQueue.main.async { handler(value) }
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
            resetTransientState(mouse: true, holds: true)
            updateMask()
        }
    }

    /// Tap thread: the key holding the overview went up (or is forgotten): it closes.
    private func closeOverview() {
        Self.onMain(onOverview, false)
    }

    /// Tap thread: forgets what is held or owed, so nothing stays stuck once events were missed
    /// or mean something else: the keys, the combinations' modifiers and the overview; with
    /// `mouse`, the button-ups and click-ups owed and a drag in progress too; with `holds`,
    /// the trackpad's pointer and click holds as well.
    private func resetTransientState(mouse: Bool, holds: Bool) {
        if state.resetKeys() { closeOverview() }
        guard mouse else { return }
        state.clearButtons()
        droppedClicks = (false, false)
        cancelDrag()
        guard holds else { return }
        heldPointer = nil
        cornerClicksHeld = false
        cornerClicksUntil = 0
    }

    /// Tap thread: a modifier-drag whose mouse-up will not be seen (a new config, a tap that
    /// timed out) ends where the pointer is, so the window manager does not wait for it.
    private func cancelDrag() {
        guard activeDrag != nil else { return }
        activeDrag = nil
        drag.cancel()
    }

    /// Locks for `KeyboardLock.minutes` (or until unlocked when 0), or unlocks.
    func setKeyboardLocked(_ locked: Bool) {
        guard locked != isKeyboardLocked else { return }
        // Without the permission there is no tap to ignore the keys: a lock would only claim to be on.
        if locked, isTapUnavailable || !Permissions.isTrusted(prompt: false) {
            log.error("keyboard not locked: \(self.isTapUnavailable ? "no event tap" : "Accessibility permission missing", privacy: .public)")
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
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                self?.setKeyboardLocked(false)
            }
            // Common modes: the lock also lifts on time while a menu is open.
            RunLoop.main.add(timer, forMode: .common)
            unlockTimer = timer
        }
        log.info("keyboard \(locked ? "locked" : "unlocked", privacy: .public)")
        // A remapped caps lock pressed while locked was dropped before it could be switched off.
        if !locked, requestedConfig?.suppressCapsLock == true { CapsLock.turnOff() }
        onTapThread { [self] in
            keyboardLocked = locked
            resetTransientState(mouse: false, holds: false)
            updateMask()
        }
        NotificationCenter.default.post(name: Self.keyboardLockDidChange, object: self)
    }

    /// Main thread: the tap could not be made, or could again. A lock that no tap enforces is
    /// lifted: it would only claim to be on.
    private func setTapUnavailable(_ unavailable: Bool) {
        guard unavailable != isTapUnavailable else { return }
        isTapUnavailable = unavailable
        if unavailable, isKeyboardLocked {
            NSSound.beep()
            setKeyboardLocked(false)
        }
        NotificationCenter.default.post(name: Self.tapAvailabilityDidChange, object: self)
    }

    /// The events the config needs, plus every keyboard event while locked.
    private func updateMask() {
        var newMask = config.eventMask
        if keyboardLocked {
            for type in [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue,
                         SystemDefinedEvent.type] {
                newMask |= CGEventMask(1) << type
            }
        }
        if newMask != mask || (tap == nil && newMask != 0) { installTap(mask: newMask) }
    }

    /// Holds the pointer where it is, or lets it go (the trackpad edge sliders). Safe to call
    /// from any thread: the multitouch thread calls it, so the hold starts without a detour
    /// through the main thread. A hold lasts `holdTimeout` at most: asked again, it goes on.
    func setPointerHeld(_ held: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        onTapThread { [self] in
            guard config.holdsPointer || !held else { return }
            heldPointer = held ? (heldPointer ?? Pointer.eventLocation) : nil
            heldPointerUntil = now + Self.holdTimeout
        }
    }

    /// Drops clicks while a finger is down in a trackpad corner with an action (`held`), and
    /// for a moment after it is lifted from a tap (`grace`). Safe to call from any thread.
    func setCornerClicksHeld(_ held: Bool, grace: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        onTapThread { [self] in
            guard config.holdsCornerClicks || !held else { return }
            cornerClicksHeld = held
            cornerClicksHeldUntil = now + Self.holdTimeout
            cornerClicksUntil = !held && grace ? now + Self.cornerClickGrace : 0
        }
    }

    /// Tap thread: whether a click now comes from a tap in a trackpad corner. A hold nobody
    /// ended (the trackpad went away) and a grace that ran out are over.
    private func droppingCornerClicks() -> Bool {
        guard cornerClicksHeld || cornerClicksUntil != 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if cornerClicksHeld, now >= cornerClicksHeldUntil { cornerClicksHeld = false }
        if cornerClicksUntil != 0, now >= cornerClicksUntil { cornerClicksUntil = 0 }
        return cornerClicksHeld || cornerClicksUntil != 0
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
        guard newMask != 0 else {
            // No tap needed any more: none is missing either.
            tapCreation(failed: false)
            return
        }

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: newMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("cannot create event tap (Accessibility permission missing?)")
            tapCreation(failed: true)
            return
        }
        tapCreation(failed: false)
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
    }

    /// Tap thread: tells the main thread when making the tap starts or stops failing, and
    /// while it fails has it tried again every `tapRetryInterval` (the grant may come back).
    private func tapCreation(failed: Bool) {
        if failed != tapFailed {
            tapFailed = failed
            DispatchQueue.main.async { [self] in setTapUnavailable(failed) }
        }
        guard failed, !tapRetryScheduled else { return }
        tapRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapRetryInterval) { [self] in
            onTapThread { [self] in
                tapRetryScheduled = false
                updateMask()
            }
        }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Events were missed meanwhile: the mouse-up of a drag perhaps, or the key-up of a
            // combination's key, whose modifiers would stay on every event after.
            resetTransientState(mouse: true, holds: false)
            return pass
        default:
            break
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        if keyboardLocked {
            switch type {
            case .keyDown, .keyUp, .flagsChanged: return nil
            case _ where type.rawValue == SystemDefinedEvent.type:
                // Only the media, volume and brightness keys: other subtypes come from the mouse.
                return NSEvent(cgEvent: event)?.subtype.rawValue == SystemDefinedEvent.mediaKeySubtype ? nil : pass
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
            guard DispatchTime.now().uptimeNanoseconds < heldPointerUntil else {
                // Nobody renewed the hold: the trackpad that asked for it is gone.
                heldPointer = nil
                return pass
            }
            // Dropped; and should the pointer have moved anyway, it goes back.
            if !event.location.isClose(to: held, tolerance: 0.5) { Pointer.warp(to: held) }
            return nil
        case .leftMouseDown, .rightMouseDown:
            let mode: DragMode = type == .leftMouseDown ? .move : .resize
            if activeDrag != nil {
                // During a drag the window keeps its gesture: another press neither restarts
                // nor ends it, and the app sees neither it nor its release.
                if activeDrag?.mode != mode { activeDrag?.otherButtonDown = true }
                return nil
            }
            if config.holdsCornerClicks, droppingCornerClicks() {
                if type == .leftMouseDown { droppedClicks.0 = true } else { droppedClicks.1 = true }
                return nil
            }
            return beginDrag(event, mode: mode) ? nil : pass
        case .leftMouseDragged, .rightMouseDragged:
            // Either type: with both buttons down macOS may report the drag as the other one's.
            guard activeDrag != nil else { return pass }
            drag.update(event.location)
            return nil
        case .leftMouseUp, .rightMouseUp:
            if type == .leftMouseUp ? droppedClicks.0 : droppedClicks.1 {
                if type == .leftMouseUp { droppedClicks.0 = false } else { droppedClicks.1 = false }
                return nil
            }
            guard let current = activeDrag else { return pass }
            let mode: DragMode = type == .leftMouseUp ? .move : .resize
            guard mode == current.mode else {
                // The other button: swallowed only if its press was.
                guard current.otherButtonDown else { return pass }
                activeDrag?.otherButtonDown = false
                return nil
            }
            activeDrag = nil
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
            Self.onMain(onOverview, shown)
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
        // Every delta is read before any is written: setting the line delta may make the
        // system work the other two out again, and those would then be reversed twice.
        let lines = (event.getIntegerValueField(.scrollWheelEventDeltaAxis1), event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let points = (event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        let fixed = (event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lines.0)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lines.1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed.0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixed.1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -points.0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -points.1)
    }

    private func beginDrag(_ event: CGEvent, mode: DragMode) -> Bool {
        guard let required = config.dragModifier, Modifiers(event.flags) == required else { return false }
        activeDrag = Drag(mode: mode)
        drag.begin(mode, at: event.location)
        return true
    }

    private func dispatch(_ action: Action) {
        Self.onMain(onAction, action)
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
