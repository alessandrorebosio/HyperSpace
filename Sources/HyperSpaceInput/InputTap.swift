import CoreGraphics
import Foundation
import HyperSpaceCore
import Synchronization

/// L1: one active CGEventTap on its own high-priority thread. The callback only does table
/// lookups and in-place event rewrites; anything slow (shell, WM) is handed off.
public final class InputTap: @unchecked Sendable {
    /// Marks events HyperSpace posts itself, so the tap lets them through.
    static let marker: Int64 = 0x4859_5350 // "HYSP"

    private let log = HyperSpace.logger("input-tap")
    /// Swapped as a whole by the main thread; reading it costs one retain, not a table copy.
    private final class Snapshot: Sendable {
        let tables: ActiveTables
        init(_ tables: ActiveTables) { self.tables = tables }
    }

    private let snapshot = Mutex(Snapshot(InputPlan().tables(forApp: nil)))
    private let perform: @Sendable (Output) -> Void
    private let capsLock: CapsLockState

    // Input thread only.
    private var engine = KeyEngine()
    private var mouse = MouseEngine()
    private var navigation = NavigationSender()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    /// - Parameter perform: runs `.shell` and `.wm` outputs; called on the input thread, must not block.
    init(capsLock: CapsLockState, perform: @escaping @Sendable (Output) -> Void) {
        self.capsLock = capsLock
        self.perform = perform
    }

    public func update(_ tables: ActiveTables) {
        let new = Snapshot(tables)
        snapshot.withLock { $0 = new }
    }

    private var current: Snapshot { snapshot.withLock { $0 } }

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
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        self.port = nil
        self.runLoop = nil
    }

    private func installTap() -> Bool {
        let types: [CGEventType] = [
            .keyDown, .keyUp,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
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

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // Events HyperSpace posted itself (keys, navigation buttons) go through untouched.
        if event.getIntegerValueField(.eventSourceUserData) == InputTap.marker {
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            log.warning("event tap was disabled by the system, re-enabled")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return handleButton(type, event)
        case .rightMouseDragged, .otherMouseDragged:
            if mouse.isSwallowed(Int(event.getIntegerValueField(.mouseEventButtonNumber))) {
                event.type = .mouseMoved
            }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            if let scroll = current.tables.scroll, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 {
                InputTap.adjust(event, scroll)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
        let tables = current.tables
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if let layer = tables.layer, layer.led == .held, code == Layer.trigger.code, !isRepeat {
            capsLock.set(type == .keyDown) // LED on while Caps Lock is held
        }
        let decision = engine.handle(code: code, down: type == .keyDown, isRepeat: isRepeat,
                                     now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), tables: tables)
        // The LED is the caps lock state: keep it from turning keys into capitals.
        if engine.isLayerHeld { event.flags.remove(.maskAlphaShift) }

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
            emit(output, for: event)
            return nil
        }
    }

    /// Performs an output outside of any input event (`hsctl do`), on the input thread.
    /// Returns false if the tap isn't running.
    public func run(_ output: Output, targetPID: pid_t) -> Bool {
        guard let runLoop else { return false }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            emit(output, pid: targetPID, location: CGEvent(source: nil)?.location ?? .zero)
        }
        CFRunLoopWakeUp(runLoop)
        return true
    }

    private func handleButton(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = mouse.button(
            Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            down: type == .rightMouseDown || type == .otherMouseDown,
            tables: current.tables
        )
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case let .emit(output):
            emit(output, for: event)
            return nil
        }
    }

    private func emit(_ output: Output, for event: CGEvent) {
        emit(output, pid: pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID)), location: event.location)
    }

    private func emit(_ output: Output, pid: pid_t, location: CGPoint) {
        switch output {
        case let .key(combo):
            Post.combo(combo)
        case .system(.navigateBack), .system(.navigateForward):
            navigation.send(output == .system(.navigateBack) ? .back : .forward, targetPID: pid,
                            location: location, rules: current.tables.navigation)
        case let .system(action):
            SystemActions.perform(action, at: location)
        case let .scroll(step):
            Post.scroll(step)
        case .shell, .wm:
            perform(output)
        case .drop:
            break
        }
    }

    /// Wheel scrolling only (notched mice): reverse it and/or make it a fixed number of lines
    /// per notch, without macOS acceleration.
    static func adjust(_ event: CGEvent, _ scroll: ScrollConfig) {
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
        ]
        for (lineField, fixedField, pointField) in axes {
            var lines = event.getIntegerValueField(lineField)
            var fixed = event.getDoubleValueField(fixedField)
            var points = event.getIntegerValueField(pointField)
            guard lines != 0 || fixed != 0 || points != 0 else { continue }

            if scroll.linear {
                let direction: Int64 = (lines != 0 ? lines.signum() : points != 0 ? points.signum() : fixed < 0 ? -1 : 1)
                    * (scroll.reverse ? -1 : 1)
                let perNotch = Int64(scroll.lines ?? 3)
                lines = direction * perNotch
                fixed = Double(lines)
                points = lines * 10
            } else if scroll.reverse {
                lines = -lines
                fixed = -fixed
                points = -points
            }
            event.setIntegerValueField(lineField, value: lines)
            event.setDoubleValueField(fixedField, value: fixed)
            event.setIntegerValueField(pointField, value: points)
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
