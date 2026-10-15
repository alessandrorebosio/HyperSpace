import Foundation
import HyperSpaceCore
import IOKit.hidsystem

/// L0: applies `UserKeyMapping` to keyboard services (what `hidutil` does). Needs no permission
/// and works in password fields too. Reapplied when a keyboard connects or the Mac wakes;
/// each keyboard's previous mapping comes back on `restore()`.
@MainActor
final class HIDMapper {
    private let log = HyperSpace.logger("hid-mapper")
    private let services: HIDServices
    private let property = "UserKeyMapping" as CFString
    private var mappings: [HIDMapping] = []
    /// Mapping found on each service (by registry id) before HyperSpace touched it.
    private var original: [UInt64: CFTypeRef?] = [:]

    private(set) var mappedKeyboards = 0

    init(services: HIDServices) {
        self.services = services
        services.onChange.append { [weak self] in
            if self?.mappings.isEmpty == false { self?.applyToAll() }
        }
    }

    /// Unchanged mappings aren't written again: every config reload calls this.
    func apply(_ mappings: [HIDMapping]) {
        guard mappings != self.mappings else { return }
        self.mappings = mappings
        applyToAll()
    }

    func restore() { apply([]) }

    private func applyToAll() {
        var mapped = 0
        for service in services.keyboards {
            let id = HIDServices.registryID(service)
            if original[id] == nil {
                original[id] = .some(IOHIDServiceClientCopyProperty(service, property))
            }
            // First mapping per key wins: device-specific ones come first in the plan.
            var seen = Set<UInt32>()
            let entries = mappings.filter { HIDServices.matches($0.device, service) && seen.insert($0.from).inserted }
            if entries.isEmpty {
                IOHIDServiceClientSetProperty(service, property, (original[id] ?? nil) ?? ([] as CFArray))
            } else {
                let value = entries.map {
                    ["HIDKeyboardModifierMappingSrc": 0x7_0000_0000 | UInt64($0.from),
                     "HIDKeyboardModifierMappingDst": 0x7_0000_0000 | UInt64($0.to)]
                }
                if IOHIDServiceClientSetProperty(service, property, value as CFArray) { mapped += 1 }
            }
        }
        mappedKeyboards = mapped
        log.info("applied \(self.mappings.count) HID mapping(s) to \(mapped) keyboard(s)")
    }
}
