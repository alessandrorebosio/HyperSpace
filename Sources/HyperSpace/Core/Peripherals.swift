import Foundation
import IOKit

/// Battery level of a wireless keyboard, mouse or trackpad.
struct PeripheralBattery: Equatable {
    enum Kind { case keyboard, mouse, trackpad, other }

    let name: String
    let kind: Kind
    let percent: Int
    let charging: Bool

    var isLow: Bool { percent <= 15 && !charging }

    /// SF Symbol for the device.
    var symbol: String {
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

/// Reads the battery of Bluetooth input devices from the IOKit registry: Apple's devices report
/// it on their `AppleDeviceManagementHIDEventService`, other Bluetooth LE devices (the HID battery
/// service) on their `IOHIDDevice`. Read on demand (when the menu opens); nothing is polled.
enum Peripherals {
    static func batteries() -> [PeripheralBattery] {
        var found: [PeripheralBattery] = []
        for serviceClass in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let battery = battery(of: service), !found.contains(where: { $0.name == battery.name }) else { continue }
                found.append(battery)
            }
        }
        return found.sorted { ($0.kind.rank, $0.name) < ($1.kind.rank, $1.name) }
    }

    private static func battery(of service: io_object_t) -> PeripheralBattery? {
        guard let percent = (property(service, "BatteryPercent") as? NSNumber)?.intValue, (1...100).contains(percent) else { return nil }
        let name = property(service, "Product") as? String ?? "Wireless device"
        let page = (property(service, "PrimaryUsagePage") as? NSNumber)?.intValue
        let usage = (property(service, "PrimaryUsage") as? NSNumber)?.intValue
        let kind: PeripheralBattery.Kind
        if name.localizedCaseInsensitiveContains("trackpad") {
            kind = .trackpad
        } else if name.localizedCaseInsensitiveContains("keyboard") || (page == 1 && usage == 6) {
            kind = .keyboard
        } else if name.localizedCaseInsensitiveContains("mouse") || (page == 1 && usage == 2) {
            kind = .mouse
        } else {
            kind = .other
        }
        // BatteryStatusFlags: bit 1 (value 2) means charging on Apple devices.
        let flags = (property(service, "BatteryStatusFlags") as? NSNumber)?.intValue ?? 0
        return PeripheralBattery(name: name, kind: kind, percent: percent, charging: flags & 2 != 0)
    }

    /// A property of the service or, failing that, of the devices above it.
    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}

private extension PeripheralBattery.Kind {
    var rank: Int {
        switch self {
        case .keyboard: return 0
        case .mouse: return 1
        case .trackpad: return 2
        case .other: return 3
        }
    }
}
