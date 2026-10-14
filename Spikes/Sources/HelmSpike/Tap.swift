import CoreGraphics
import Foundation

/// S1 + L1: one CGEventTap for keyboard, mouse buttons and scroll.
enum Tap {
    /// Marks events we post ourselves so the tap lets them through.
    static let marker: Int64 = 0x4845_4C4D // "HELM"

    static let f18: Int64 = 79
    /// Caps (as F18) layer used by --remap: hjkl -> arrows.
    static let layerMap: [Int64: CGKeyCode] = [4: 123, 38: 125, 40: 126, 37: 124]

    static var port: CFMachPort?
    static var remap = false
    static var layerDown = false
    static var layerUsed = false
    static var worstCallbackNs: UInt64 = 0
    static var timebase = mach_timebase_info_data_t()

    static func run(remap: Bool, duration: Double) {
        self.remap = remap
        mach_timebase_info(&timebase)

        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: remap ? .defaultTap : .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: nil
        ) else {
            print("FAIL  CGEvent.tapCreate returned nil: the responsible app lacks Accessibility (active tap) or Input Monitoring (listen-only keyboard)")
            exit(2)
        }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        print("OK  tap created (\(remap ? "active, remapping" : "listen-only")), running \(Int(duration))s")
        if remap {
            print("    mouse back/forward -> cmd-[ / cmd-]; F18 (Caps after `capslock set`) + hjkl -> arrows")
        }
        CFRunLoopRunInMode(.defaultMode, duration, false)
        let worstUs = Double(worstCallbackNs * UInt64(timebase.numer) / UInt64(timebase.denom)) / 1000
        print(String(format: "done. slowest callback (excluding logging): %.1f µs", worstUs))
    }

    static let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("tap disabled (\(type.rawValue)), re-enabling")
            if let port = Tap.port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Tap.marker {
            return Unmanaged.passUnretained(event)
        }
        Tap.describe(type, event)
        let t0 = mach_absolute_time()
        let result = Tap.handle(type, event)
        Tap.worstCallbackNs = max(Tap.worstCallbackNs, mach_absolute_time() - t0)
        return result.map { Unmanaged.passUnretained($0) }
    }

    static func describe(_ type: CGEventType, _ e: CGEvent) {
        let flags = hex(e.flags.rawValue, width: 6)
        switch type {
        case .keyDown, .keyUp:
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            let repeatTag = e.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? " (repeat)" : ""
            log("key    \(type == .keyDown ? "down" : "up  ") code=\(code) flags=\(flags)\(repeatTag)")
        case .flagsChanged:
            log("flags  code=\(e.getIntegerValueField(.keyboardEventKeycode)) flags=\(flags)")
        case .otherMouseDown, .otherMouseUp:
            log("mouse  \(type == .otherMouseDown ? "down" : "up  ") button=\(e.getIntegerValueField(.mouseEventButtonNumber)) subtype=\(e.getIntegerValueField(.mouseEventSubtype))")
        case .scrollWheel:
            log("scroll lines=(\(e.getIntegerValueField(.scrollWheelEventDeltaAxis1)), \(e.getIntegerValueField(.scrollWheelEventDeltaAxis2))) "
                + "points=(\(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)), \(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))) "
                + "continuous=\(e.getIntegerValueField(.scrollWheelEventIsContinuous)) "
                + "phase=\(e.getIntegerValueField(.scrollWheelEventScrollPhase)) momentum=\(e.getIntegerValueField(.scrollWheelEventMomentumPhase))")
        default:
            break
        }
    }

    /// Returns the event to deliver, or nil to swallow it.
    static func handle(_ type: CGEventType, _ e: CGEvent) -> CGEvent? {
        guard remap else { return e }
        switch type {
        case .keyDown, .keyUp:
            let code = e.getIntegerValueField(.keyboardEventKeycode)
            let down = type == .keyDown
            if code == f18 {
                if down, !layerDown {
                    layerDown = true
                    layerUsed = false
                } else if !down {
                    layerDown = false
                    if !layerUsed { log("  layer: Caps tapped alone -> nothing") }
                }
                return nil
            }
            guard layerDown else { return e }
            layerUsed = true
            guard let to = layerMap[code] else { return e } // unmapped: normal behavior
            e.setIntegerValueField(.keyboardEventKeycode, value: Int64(to))
            e.flags.formUnion([.maskSecondaryFn, .maskNumericPad]) // arrows carry these flags
            return e
        case .otherMouseDown, .otherMouseUp:
            let button = e.getIntegerValueField(.mouseEventButtonNumber)
            guard button == 3 || button == 4 else { return e }
            if type == .otherMouseDown { postKey(button == 3 ? 33 : 30, flags: .maskCommand) }
            return nil
        default:
            return e
        }
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            ev.flags = flags
            ev.setIntegerValueField(.eventSourceUserData, value: marker)
            ev.post(tap: .cgSessionEventTap)
        }
    }
}
