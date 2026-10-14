import CoreGraphics
import Foundation
import HelmCore
import Synchronization

/// L1: one active CGEventTap on its own high-priority thread. The callback only does table
/// lookups and in-place event rewrites; anything slow (shell, WM) is handed off.
public final class InputTap: @unchecked Sendable {
    /// Marks events Helm posts itself, so the tap lets them through.
    static let marker: Int64 = 0x4845_4C4D // "HELM"

    private let log = Helm.logger("input-tap")
    private let tables = Mutex(ActiveTables())
    private let perform: @Sendable (Output) -> Void

    // Input thread only.
    private var engine = KeyEngine()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    /// - Parameter perform: runs `.shell` and `.wm` outputs; called on the input thread, must not block.
    public init(perform: @escaping @Sendable (Output) -> Void) {
        self.perform = perform
    }

    public func update(_ newTables: ActiveTables) {
        tables.withLock { $0 = newTables }
    }

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
        thread.name = "helm.input"
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
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // The first CGEvent created in a process costs ~100 ms (see docs/SPIKE.md): pay it now.
        _ = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            log.warning("event tap was disabled by the system, re-enabled")
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            break
        default:
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == InputTap.marker {
            return Unmanaged.passUnretained(event)
        }

        let current = tables.withLock { $0 }
        let decision = engine.handle(
            code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            down: type == .keyDown,
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            tables: current
        )

        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case let .rewrite(combo):
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(combo.key.code))
            event.flags = InputTap.flags(for: combo, physical: event.flags)
            return Unmanaged.passUnretained(event)
        case let .emit(output):
            if case let .key(combo) = output {
                InputTap.post(combo)
            } else {
                perform(output)
            }
            return nil
        }
    }

    /// Physical modifiers are kept (Shift + Caps + h selects to the left), the combo's are added.
    static func flags(for combo: Combo, physical: CGEventFlags = []) -> CGEventFlags {
        var flags = physical.subtracting([.maskSecondaryFn, .maskNumericPad])
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.fn) || combo.key.hasFnFlag { flags.insert(.maskSecondaryFn) }
        if combo.key.isArrow { flags.insert(.maskNumericPad) }
        return flags
    }

    /// Sends a full key press (down + up).
    static func post(_ combo: Combo) {
        let flags = flags(for: combo)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: combo.key.code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
