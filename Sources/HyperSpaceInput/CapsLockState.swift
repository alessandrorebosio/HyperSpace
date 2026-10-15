import Foundation
import HyperSpaceCore
import IOKit
import IOKit.hidsystem

/// Sets the caps lock state (and so the LED) of every keyboard through the HID event system.
/// No permission needed. Calls are IPC to the HID daemon, so they run on their own queue and
/// never block the input thread.
final class CapsLockState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hyperspace.capslock", qos: .userInteractive)
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    func set(_ on: Bool) {
        queue.async { [self] in
            for service in HIDKeyboards.all(client) {
                IOHIDServiceClientSetProperty(service, kIOHIDServiceCapsLockStateKey as CFString, on as CFBoolean)
            }
        }
    }
}
