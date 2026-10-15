import AppKit
import HyperSpaceCore
import IOKit
import IOKit.hidsystem

/// L0: applies `UserKeyMapping` to keyboard services (what `hidutil` does). Needs no permission
/// and works in password fields too. Re-applies when a keyboard is connected or the Mac wakes,
/// and restores each keyboard's previous mapping on `restore()`.
@MainActor
public final class HIDMapper {
    private let log = HyperSpace.logger("hid-mapper")
    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let property = "UserKeyMapping" as CFString
    private var mappings: [HIDMapping] = []
    /// Mapping found on each service (by registry id) before HyperSpace touched it.
    private var original: [UInt64: CFTypeRef?] = [:]
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var pendingReapply: Task<Void, Never>?

    public private(set) var mappedKeyboards = 0

    public init() {
        watchKeyboards()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply() }
        }
    }

    public func apply(_ mappings: [HIDMapping]) {
        self.mappings = mappings
        applyToAll()
    }

    public func restore() {
        mappings = []
        applyToAll()
    }

    private func applyToAll() {
        var mapped = 0
        for service in HIDKeyboards.all(client) {
            let id = registryID(service)
            if original[id] == nil {
                original[id] = .some(IOHIDServiceClientCopyProperty(service, property))
            }
            // First mapping per key wins: device-specific ones come first in the plan.
            var seen = Set<UInt32>()
            let entries = mappings.filter { matches($0.device, service) && seen.insert($0.from).inserted }
            if entries.isEmpty {
                let previous = original[id] ?? nil
                IOHIDServiceClientSetProperty(service, property, previous ?? ([] as CFArray))
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

    private func matches(_ device: DeviceMatch?, _ service: IOHIDServiceClient) -> Bool {
        guard let device else { return true }
        func int(_ key: String) -> Int? { IOHIDServiceClientCopyProperty(service, key as CFString) as? Int }
        if let vendor = device.vendor, int(kIOHIDVendorIDKey) != vendor { return false }
        if let product = device.product, int(kIOHIDProductIDKey) != product { return false }
        return true
    }

    private func registryID(_ service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Hot plug

    private func watchKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
            { refcon, iterator in
                HIDMapper.drain(iterator)
                guard let refcon else { return }
                let mapper = Unmanaged<HIDMapper>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { mapper.scheduleReapply() }
            },
            refcon, &iterator
        )
        if result == KERN_SUCCESS { HIDMapper.drain(iterator) } // arms the notification
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    /// The HID event system publishes a new service shortly after IOKit does: wait a bit.
    private func scheduleReapply() {
        pendingReapply?.cancel()
        pendingReapply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, !self.mappings.isEmpty else { return }
            self.applyToAll()
        }
    }
}
