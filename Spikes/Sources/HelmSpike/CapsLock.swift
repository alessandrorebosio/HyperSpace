import Foundation
import IOKit
import IOKit.hidsystem

/// L0: Caps Lock -> F18 through the HID event system (what `hidutil` does). No permissions expected.
enum CapsLock {
    static let key = "UserKeyMapping" as CFString
    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D

    static func run(_ command: String) {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        let keyboards = services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
        print("\(keyboards.count) keyboard service(s)")

        let mapping: [[String: UInt64]] = [[
            "HIDKeyboardModifierMappingSrc": capsLock,
            "HIDKeyboardModifierMappingDst": f18,
        ]]

        for service in keyboards {
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String ?? "?"
            let vendor = IOHIDServiceClientCopyProperty(service, "VendorID" as CFString) as? Int ?? 0
            let current = IOHIDServiceClientCopyProperty(service, key)
            print("- \(name) (vendor \(hex(vendor, width: 4))) current mapping: \(current.map { "\($0)" } ?? "none")")

            switch command {
            case "set":
                let ok = IOHIDServiceClientSetProperty(service, key, mapping as CFArray)
                print("  set Caps Lock -> F18: \(ok ? "OK" : "FAILED")")
            case "clear":
                let ok = IOHIDServiceClientSetProperty(service, key, [] as CFArray)
                print("  cleared: \(ok ? "OK" : "FAILED")")
            default:
                break
            }
        }
    }
}
