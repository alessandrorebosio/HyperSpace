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
            let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
            for service in services where IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 {
                IOHIDServiceClientSetProperty(service, kIOHIDServiceCapsLockStateKey as CFString, on as CFBoolean)
            }
        }
    }
}
