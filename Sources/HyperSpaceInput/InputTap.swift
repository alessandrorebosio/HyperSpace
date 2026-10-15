import AppKit
import CoreGraphics
import HyperSpaceCore
import Synchronization

/// L1: one active CGEventTap on its own high-priority thread ("hyperspace.input").
///
/// The callback only does table lookups (`KeyEngine`, `MouseEngine`) and in-place event
/// rewrites; posting goes through `Post`, and anything slow (shell, apps, AX, WM) is handed
/// off to other queues. Everything below marked "input thread" runs on that thread only.
public final class InputTap: @unchecked Sendable {
    /// Marks events HyperSpace posts itself, so the tap lets them through.
    static let marker: Int64 = 0x4859_5350 // "HYSP"

    private let log = HyperSpace.logger("input-tap")

    /// Swapped as a whole by the main thread; reading it costs one retain, not a table copy.
    private final class Snapshot: Sendable {
        let tables: ActiveTables
        /// The frontmost app: the target of outputs that don't come from a pointer event.
        let frontmostPID: pid_t
        init(_ tables: ActiveTables, _ frontmostPID: pid_t) {
            self.tables = tables
            self.frontmostPID = frontmostPID
        }
    }

    private let snapshot = Mutex(Snapshot(InputPlan().tables(forApp: nil), 0))
    private let perform: @Sendable (Output) -> Void
    private let capsLock: CapsLockState
    /// Also tap plain mouse moves (gestures on Logitech controls, focus-follows-mouse).
    /// Off otherwise: moves are the most frequent event and the tap shouldn't see them for nothing.
    private let moveEvents: Bool
    /// Pointer position for focus-follows-mouse, at most every 30 ms.
    private let mouseMoved: (@Sendable (CGPoint) -> Void)?
    private var lastMouseReport: UInt64 = 0

    // Input thread only.
    private var keys = KeyEngine()
    private var mouse = MouseEngine()
    private var navigation = NavigationSender()
    private var smooth = SmoothScroller()
    private var repeater: CFRunLoopTimer?
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    /// - Parameter perform: runs `.shell`, `.wm` and `.app` outputs; called on the input
    ///   thread, must not block.
    init(capsLock: CapsLockState, moveEvents: Bool, mouseMoved: (@Sendable (CGPoint) -> Void)? = nil,
         perform: @escaping @Sendable (Output) -> Void) {
        self.capsLock = capsLock
        self.moveEvents = moveEvents
        self.mouseMoved = mouseMoved
        self.perform = perform
    }

    public func update(_ tables: ActiveTables, frontmostPID: pid_t) {
        let new = Snapshot(tables, frontmostPID)
        snapshot.withLock { $0 = new }
    }

    private var current: Snapshot { snapshot.withLock { $0 } }

    // MARK: - Lifecycle

    /// Starts the input thread. Returns false if the tap can't be created (no Accessibility).
    public func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let created = Mutex(false)
        let thread = Thread { [self] in
            let ok = installTap()
            created.withLock { $0 = ok }
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "hyperspace.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return created.withLock { $0 }
    }

    public func stop() {
        guard let runLoop, let port else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            stopRepeat()
            smooth.stop()
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.port = nil
        self.runLoop = nil
    }

    private func installTap() -> Bool {
        var types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
        if moveEvents { types.append(.mouseMoved) }
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // The first CGEvent created in a process costs ~100 ms (see docs/SPIKE.md), and the
        // posting resources are created lazily: pay both now, not on the first remapped input.
        Post.warmUp()
        return true
    }

    // MARK: - Entry points from other threads

    /// Performs an output outside of any input event (`hsctl do`). False if the tap isn't running.
    public func run(_ output: Output) -> Bool {
        onInputThread { [self] in emit(output, pid: current.frontmostPID, location: Post.cursor) }
    }

    /// A Logitech control (read over HID++) went down or up: handled like a mouse button.
    public func logitechButton(_ index: Int, down: Bool) {
        _ = onInputThread { [self] in
            let decision = mouse.button(index, down: down, tables: current.tables)
            apply(decision, pid: current.frontmostPID, location: Post.cursor)
        }
    }

    private func onInputThread(_ block: @escaping () -> Void) -> Bool {
        guard let runLoop else { return false }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
        return true
    }

    // MARK: - Event handling (input thread)

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Events HyperSpace posted itself (keys, clicks, scrolls) go through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == InputTap.marker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .keyDown, .keyUp:
            return handleKey(type, event)
        case .flagsChanged:
            handleModifier(event)
            return Unmanaged.passUnretained(event)
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return handleButton(type, event)
        case .rightMouseDragged, .otherMouseDragged, .mouseMoved:
            handleMove(type, event)
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            return handleScroll(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            log.warning("event tap was disabled by the system, re-enabled")
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKey(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let snapshot = current
        let tables = snapshot.tables
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if code == Layer.capsLockTrigger, !isRepeat, tables.layers.first?.trigger == code, tables.layers[0].led == .held {
            capsLock.set(type == .keyDown) // LED on while Caps Lock is held
        }
        let decision = keys.handle(code: code, down: type == .keyDown, isRepeat: isRepeat,
                                   modifiers: InputTap.modifiers(event.flags),
                                   now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), tables: tables)
        // A Caps Lock LED that is on is the caps lock state: keep it from making capitals.
        if keys.isLayerHeld { event.flags.remove(.maskAlphaShift) }
        let pid = snapshot.frontmostPID
        if let before = keys.takeEmitBefore() { emit(before, pid: pid, location: Post.cursor) }

        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case let .rewrite(combo):
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(combo.key.code))
            event.flags = Post.flags(for: combo, physical: event.flags)
            return Unmanaged.passUnretained(event)
        case let .emit(output):
            emit(output, pid: pid, location: Post.cursor)
            return nil
        case let .down(output), let .up(output):
            hold(output, down: decision == .down(output), location: Post.cursor)
            return nil
        }
    }

    /// Modifier keys arrive as flag changes: watched for double taps only, never changed.
    private func handleModifier(_ event: CGEvent) {
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard let mask = InputTap.modifierMasks[code] else { return }
        let snapshot = current
        if let output = keys.modifier(code: code, down: event.flags.contains(mask),
                                      now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), tables: snapshot.tables) {
            emit(output, pid: snapshot.frontmostPID, location: Post.cursor)
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        return modifiers
    }

    private static let modifierMasks: [UInt16: CGEventFlags] = [
        56: .maskShift, 60: .maskShift, 59: .maskControl, 62: .maskControl,
        58: .maskAlternate, 61: .maskAlternate, 55: .maskCommand, 54: .maskCommand, 63: .maskSecondaryFn,
    ]

    private func handleButton(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = mouse.button(
            Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            down: type == .rightMouseDown || type == .otherMouseDown,
            tables: current.tables
        )
        if decision == .pass { return Unmanaged.passUnretained(event) }
        apply(decision, pid: InputTap.targetPID(event), location: event.location)
        return nil
    }

    private func apply(_ decision: MouseEngine.Decision, pid: pid_t, location: CGPoint) {
        switch decision {
        case .pass, .drop: break
        case let .emit(output): emit(output, pid: pid, location: location)
        case let .down(output): hold(output, down: true, location: location)
        case let .up(output): hold(output, down: false, location: location)
        case let .click(button): Post.click(button, at: location)
        }
    }

    /// Drags of a swallowed button: apps must not see a drag without a press, so they become
    /// plain moves, or drags of the button a `hold = true` click is holding down. Movement
    /// also feeds `move.*` gestures.
    private func handleMove(_ type: CGEventType, _ event: CGEvent) {
        if type != .mouseMoved, let output = mouse.swallowed(Int(event.getIntegerValueField(.mouseEventButtonNumber))) {
            if case let .held(inner) = output, let button = inner.clickButton {
                event.type = button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            } else {
                event.type = .mouseMoved
            }
        }
        if let mouseMoved {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if now &- lastMouseReport > 30_000_000 {
                lastMouseReport = now
                mouseMoved(event.location)
            }
        }
        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        if let output = mouse.move(dx: dx, dy: dy, tables: current.tables) {
            emit(output, pid: InputTap.targetPID(event), location: event.location)
        }
    }

    /// Notched wheels only: trackpads and smooth-scrolling mice send continuous events, which
    /// are left alone. Order: hold tables, then fast, smooth, linear and reverse.
    private func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(event) }
        let tables = current.tables
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        switch mouse.scroll(dx: dx, dy: dy, tables: tables) {
        case let .emit(output):
            emit(output, pid: InputTap.targetPID(event), location: event.location)
            return nil
        case .drop:
            return nil
        default:
            break
        }
        guard let scroll = tables.scroll else { return Unmanaged.passUnretained(event) }

        var factor = 1.0
        if !scroll.fast.isEmpty {
            let fast = Post.flags(for: scroll.fast)
            if event.flags.contains(fast) {
                factor = scroll.fastFactor
                event.flags.remove(fast) // or apps would read e.g. ⌥-scroll as a gesture of their own
            }
        }
        if scroll.smooth {
            let perNotch = Double(scroll.lines) * SmoothScroller.pointsPerLine * factor
            let sy = Double(dy.signum()) * (scroll.reverseVertical ? -1 : 1)
            let sx = Double(dx.signum()) * (scroll.reverseHorizontal ? -1 : 1)
            smooth.add(dx: sx * perNotch, dy: sy * perNotch)
            return nil
        }
        InputTap.adjust(event, scroll, factor: factor)
        return Unmanaged.passUnretained(event)
    }

    /// Reverses and/or makes linear (a fixed number of lines per notch, no macOS
    /// acceleration) a wheel event in place. Axis 1 is vertical, axis 2 horizontal.
    static func adjust(_ event: CGEvent, _ scroll: ScrollPlan, factor: Double) {
        adjust(event, scroll, factor: factor, .scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1,
               .scrollWheelEventPointDeltaAxis1, reverse: scroll.reverseVertical)
        adjust(event, scroll, factor: factor, .scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2,
               .scrollWheelEventPointDeltaAxis2, reverse: scroll.reverseHorizontal)
    }

    /// One axis: its delta in lines, fixed point lines and points. No allocation, it runs per notch.
    private static func adjust(_ event: CGEvent, _ scroll: ScrollPlan, factor: Double, _ lineField: CGEventField,
                               _ fixedField: CGEventField, _ pointField: CGEventField, reverse: Bool) {
        var lines = Double(event.getIntegerValueField(lineField))
        var fixed = event.getDoubleValueField(fixedField)
        var points = Double(event.getIntegerValueField(pointField))
        guard lines != 0 || fixed != 0 || points != 0 else { return }
        let sign = reverse ? -1.0 : 1.0
        if scroll.linear {
            let direction = lines != 0 ? lines.sign : points != 0 ? points.sign : fixed.sign
            lines = (direction == .minus ? -1 : 1) * Double(scroll.lines) * factor * sign
            fixed = lines
            points = lines * 10
        } else {
            lines *= factor * sign
            fixed *= factor * sign
            points *= factor * sign
        }
        event.setIntegerValueField(lineField, value: Int64(lines.rounded()))
        event.setDoubleValueField(fixedField, value: fixed)
        event.setIntegerValueField(pointField, value: Int64(points.rounded()))
    }

    // MARK: - Outputs (input thread)

    private func emit(_ output: Output, pid: pid_t, location: CGPoint) {
        switch output {
        case .drop:
            break
        case let .key(combo):
            Post.combo(combo)
        case .system(.navigateBack), .system(.navigateForward):
            navigation.send(output == .system(.navigateBack) ? .back : .forward, targetPID: pid,
                            location: location, rules: current.tables.navigation)
        case let .system(action):
            SystemActions.perform(action, at: location)
        case let .scroll(step):
            Post.scroll(step)
        case let .text(text):
            Post.text(text)
        case let .sequence(outputs):
            for output in outputs { emit(output, pid: pid, location: location) }
        case let .repeating(inner), let .held(inner):
            emit(inner, pid: pid, location: location) // no release to wait for: once
        case .shell, .wm, .app:
            perform(output)
        }
    }

    /// Presses or releases a held output, or starts or stops a repeating one.
    private func hold(_ output: Output, down: Bool, location: CGPoint) {
        switch output {
        case let .held(.key(combo)):
            Post.key(combo.key.code, down: down, flags: Post.flags(for: combo))
        case let .held(inner):
            if let button = inner.clickButton { Post.button(button, down: down, at: location) }
        case let .repeating(inner):
            stopRepeat()
            guard down else { return }
            emit(inner, pid: current.frontmostPID, location: location)
            startRepeat(inner)
        default:
            break
        }
    }

    /// Repeats at the user's key repeat delay and rate (System Settings > Keyboard).
    private func startRepeat(_ output: Output) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + NSEvent.keyRepeatDelay,
                                                    NSEvent.keyRepeatInterval, 0, 0) { [self] _ in
            emit(output, pid: current.frontmostPID, location: Post.cursor)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
        repeater = timer
    }

    private func stopRepeat() {
        if let repeater { CFRunLoopTimerInvalidate(repeater) }
        repeater = nil
    }

    private static func targetPID(_ event: CGEvent) -> pid_t {
        pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
