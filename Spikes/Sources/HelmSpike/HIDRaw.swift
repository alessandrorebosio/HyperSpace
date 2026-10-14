import Foundation
import IOKit.hid

/// S2: raw HID input values from pointer devices and every Logitech interface, no seize.
enum HIDRaw {
    static var movementValues = 0

    static func run(duration: Double) {
        print("IOHIDCheckAccess(ListenEvent) = \(Perms.accessName(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)))")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDVendorIDKey: 0x046D],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        print("\(devices.count) matching device interface(s)")

        for device in devices {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            print("- \(describe(device)) open: \(ioReturnName(result))")
            guard result == kIOReturnSuccess else { continue }
            IOHIDDeviceRegisterInputValueCallback(device, valueCallback, nil)
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }

        print("listening \(Int(duration))s: press every button, scroll, tilt the wheel...")
        CFRunLoopRunInMode(.defaultMode, duration, false)
        print("done. (\(movementValues) X/Y movement values not shown)")
    }

    static func describe(_ device: IOHIDDevice) -> String {
        func prop(_ key: String) -> Any? { IOHIDDeviceGetProperty(device, key as CFString) }
        let name = prop(kIOHIDProductKey) as? String ?? "?"
        let vendor = prop(kIOHIDVendorIDKey) as? Int ?? 0
        let product = prop(kIOHIDProductIDKey) as? Int ?? 0
        let transport = prop(kIOHIDTransportKey) as? String ?? "?"
        let page = prop(kIOHIDPrimaryUsagePageKey) as? Int ?? 0
        let usage = prop(kIOHIDPrimaryUsageKey) as? Int ?? 0
        return "\(name) [\(hex(vendor, width: 4)):\(hex(product, width: 4)) \(transport) usage \(hex(page, width: 4)):\(hex(usage))]"
    }

    static let valueCallback: IOHIDValueCallback = { _, _, sender, value in
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        if page == UInt32(kHIDPage_GenericDesktop), usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y) {
            HIDRaw.movementValues += 1
            return
        }
        let name = sender.map { IOHIDDeviceGetProperty(Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue(), kIOHIDProductKey as CFString) as? String ?? "?" } ?? "?"
        let length = IOHIDValueGetLength(value)
        let detail = length > 4
            ? hex(Array(UnsafeBufferPointer(start: IOHIDValueGetBytePtr(value), count: length)))
            : "\(IOHIDValueGetIntegerValue(value))"
        log("\(name): usage \(hex(page, width: 4)):\(hex(usage, width: 4)) = \(detail)")
    }
}
