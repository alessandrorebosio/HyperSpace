import AppKit
import CoreGraphics

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
    private var config = TapConfig()
    private var carrierDown: [Bool] = []
    /// Modifiers of the modifier-only combinations currently held (e.g. caps lock → ⌃⌥⇧).
    private var heldModifiers: Modifiers = []
    private var swallowedKeys = [Bool](repeating: false, count: 128)
    private var swallowedButtons = [Bool](repeating: false, count: 32)
    /// The key code holding the workspace overview open, or -1.
    private var overviewKey = -1
    /// Set while the settings window captures a mouse button: buttons reach the app unmapped.
    private var buttonsSuspended = false
    /// Set while the settings window captures a shortcut: key bindings are ignored
    /// (combination keys still work, so caps lock → ⌃⌥⇧ can be part of the shortcut).
    private var keyBindingsSuspended = false
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
            config = translated
            resetHeldState(includingMouse: true)
            updateMask()
        }
    }

    /// Tap thread: forgets the keys, carriers and modifiers held or swallowed, so nothing
    /// stays stuck after the config or the lock changes. The mouse state goes too on a new config.
    private func resetHeldState(includingMouse: Bool) {
        carrierDown = [Bool](repeating: false, count: config.carriers.count)
        heldModifiers = []
        clearSwallowedKeys()
        if includingMouse {
            dragMode = nil
            heldPointer = nil
            clearSwallowedButtons()
        }
    }

    /// Tap thread: the key-ups still owed to a swallowed key down are not swallowed any more.
    private func clearSwallowedKeys() {
        for i in swallowedKeys.indices { swallowedKeys[i] = false }
        releaseOverview()
    }

    /// Tap thread: the key holding the overview went up (or is forgotten): it closes.
    private func releaseOverview() {
        guard overviewKey >= 0 else { return }
        overviewKey = -1
        let onOverview = onOverview
        DispatchQueue.main.async { onOverview(false) }
    }

    /// Tap thread: the same for mouse buttons.
    private func clearSwallowedButtons() {
        for i in swallowedButtons.indices { swallowedButtons[i] = false }
    }

    /// Locks for `KeyboardLock.minutes` (or until unlocked when 0), or unlocks.
    func setKeyboardLocked(_ locked: Bool) {
        guard locked != isKeyboardLocked else { return }
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
            resetHeldState(includingMouse: false)
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
        onTapThread { [self] in
            buttonsSuspended = suspended
            clearSwallowedButtons()
        }
    }

    func setKeyBindingsSuspended(_ suspended: Bool) {
        onTapThread { [self] in
            keyBindingsSuspended = suspended
            clearSwallowedKeys()
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
        if !heldModifiers.isEmpty {
            // Unbound chords still reach apps with the combination's modifiers.
            event.flags.formUnion(heldModifiers.cgFlags)
        }

        switch type {
        case .keyDown, .keyUp:
            return handleKey(event, down: type == .keyDown) ? nil : pass
        case .otherMouseDown, .otherMouseUp:
            return handleButton(event, down: type == .otherMouseDown) ? nil : pass
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

    /// Returns true when the event must be swallowed.
    private func handleKey(_ event: CGEvent, down: Bool) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard (0..<128).contains(code) else { return false }

        let carrierIndex = Int(config.carrierTable[code])
        if carrierIndex >= 0 {
            handleCarrier(carrierIndex, event, down: down)
            return true
        }
        if keyBindingsSuspended { return false }
        if down {
            let index = config.keyTable[TapConfig.slot(code, Modifiers(event.flags))]
            guard index >= 0 else { return false }
            swallowedKeys[code] = true
            let action = config.actions[Int(index)]
            if action == .workspaceOverview {
                // Open while the key is down: autorepeat changes nothing, the key up closes it.
                guard overviewKey != code else { return true }
                overviewKey = code
                let onOverview = onOverview
                DispatchQueue.main.async { onOverview(true) }
                return true
            }
            dispatch(action)
            return true
        }
        if swallowedKeys[code] {
            swallowedKeys[code] = false
            if code == overviewKey { releaseOverview() }
            return true
        }
        return false
    }

    /// A carrier key stands for a combination: modifier-only combinations are held
    /// while it is down; combinations with a key press that key with the modifiers.
    private func handleCarrier(_ index: Int, _ event: CGEvent, down: Bool) {
        let carrier = config.carriers[index]
        if let keyCode = carrier.keyCode {
            let flags = Modifiers(event.flags).union(carrier.modifiers).cgFlags
            KeyEmitter.post(keyCode: keyCode, flags: flags, down: down)
            return
        }
        guard carrierDown[index] != down else { return } // autorepeat
        carrierDown[index] = down
        var held: Modifiers = []
        for (i, isDown) in carrierDown.enumerated() where isDown { held.formUnion(config.carriers[i].modifiers) }
        heldModifiers = held
    }

    private func handleButton(_ event: CGEvent, down: Bool) -> Bool {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard (0..<32).contains(button), !buttonsSuspended else { return false }
        if down {
            let index = config.buttonTable[TapConfig.slot(button, Modifiers(event.flags))]
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
