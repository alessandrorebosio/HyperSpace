import Foundation
import HyperSpaceCore
import IOKit.hidsystem

/// Pointer speed and acceleration per device, set as HID service properties, the way
/// System Settings and LinearMouse do it (MIT, see THIRD_PARTY.md). No permission needed.
/// Each device gets its original values back when its settings go away or on `restore()`.
@MainActor
final class PointerSettings {
    private let log = HyperSpace.logger("pointer")
    private let services: HIDServices
    private var plan = PointerPlan()
    /// Values found on each service (by registry id) before HyperSpace changed them.
    private var original: [UInt64: Saved] = [:]

    private struct Saved {
        var resolution: Int?
        var acceleration: Int?
        var linear: Int?
    }

    private enum Key {
        static let resolution = kIOHIDPointerResolutionKey
        static let accelerationType = kIOHIDPointerAccelerationTypeKey
        static let mouseAcceleration = kIOHIDMouseAccelerationTypeKey
        /// macOS 14+: acceleration off, the pointer moves linearly with the mouse.
        static let linear = "HIDUseLinearScalingMouseAcceleration"
    }

    init(services: HIDServices) {
        self.services = services
        services.onChange.append { [weak self] in
            if self?.plan.isEmpty == false { self?.applyToAll() }
        }
    }

    func apply(_ plan: PointerPlan) {
        guard plan != self.plan else { return }
        self.plan = plan
        applyToAll()
    }

    func restore() { apply(PointerPlan()) }

    private func applyToAll() {
        var configured = 0
        for service in services.pointers {
            let id = HIDServices.registryID(service)
            let name = HIDServices.name(service)
            // Trackpads report as pointers too: `[pointer]` is for mice only.
            let isMouse = IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                && !name.localizedCaseInsensitiveContains("trackpad")
            let settings = plan.settings(name: name, vendor: HIDServices.property(service, kIOHIDVendorIDKey),
                                         product: HIDServices.property(service, kIOHIDProductIDKey), isMouse: isMouse)
            let accelerationKey: String = HIDServices.property(service, Key.accelerationType) ?? Key.mouseAcceleration
            guard let settings else {
                if let saved = original.removeValue(forKey: id) { restore(service, saved, accelerationKey) }
                continue
            }
            if original[id] == nil {
                original[id] = Saved(resolution: HIDServices.property(service, Key.resolution),
                                     acceleration: HIDServices.property(service, accelerationKey),
                                     linear: HIDServices.property(service, Key.linear))
            }
            if let speed = settings.speed {
                set(service, Key.resolution, PointerSettings.resolution(speed: speed))
            }
            switch settings.acceleration {
            case .off?:
                if original[id]?.linear != nil {
                    set(service, Key.linear, 1)
                } else {
                    set(service, accelerationKey, -0x10000) // before macOS 14: -1 turns it off
                }
            case let .curve(value)?:
                if original[id]?.linear != nil { set(service, Key.linear, 0) }
                set(service, accelerationKey, Int(value * 0x10000))
            case nil:
                // A new resolution takes effect once acceleration is set again.
                if settings.speed != nil, let current: Int = HIDServices.property(service, accelerationKey) {
                    set(service, accelerationKey, current)
                }
            }
            configured += 1
        }
        log.info("pointer settings applied to \(configured) device(s)")
    }

    private func restore(_ service: IOHIDServiceClient, _ saved: Saved, _ accelerationKey: String) {
        if let linear = saved.linear { set(service, Key.linear, linear) }
        if let resolution = saved.resolution { set(service, Key.resolution, resolution) }
        if let acceleration = saved.acceleration { set(service, accelerationKey, acceleration) }
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ value: Int) {
        IOHIDServiceClientSetProperty(service, key as CFString, value as CFNumber)
    }

    /// Speed 0...1 -> HID resolution (16.16 fixed point, 10...1995 dpi): the lower the
    /// resolution, the faster the pointer. Same curve as LinearMouse.
    static func resolution(speed: Double) -> Int {
        let slow = 1.0 / 1200, fast = 1.0 / 40
        let dpi = min(max(1 / (slow + speed * (fast - slow)), 10), 1995)
        return Int(dpi * 0x10000)
    }
}
