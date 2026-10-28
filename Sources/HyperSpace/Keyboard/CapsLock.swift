import IOKit
import IOKit.hidsystem

/// The system caps lock lock state.
///
/// On recent macOS the HID layer still toggles caps lock when the key is remapped
/// with UserKeyMapping, so a remapped caps lock would type its new key *and* turn
/// caps lock on. We switch the lock back off whenever that happens.
enum CapsLock {
    private static let connect: io_connect_t = {
        var connect: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        defer { IOObjectRelease(service) }
        IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        return connect
    }()

    static func turnOff() {
        guard connect != 0 else { return }
        var on = false
        guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on) == KERN_SUCCESS, on else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
    }
}
