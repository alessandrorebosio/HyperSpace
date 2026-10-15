import AppKit
import HyperSpaceCore
import IOKit
import IOKit.hidsystem

/// The HID event system's keyboard and pointer services, which take per-device properties
/// (key mappings, pointer speed) with no permission. Properties are lost when a device is
/// reconnected or the Mac wakes, so `onChange` fires (debounced, main thread) to reapply them.
@MainActor
final class HIDServices {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    /// Called after devices were added or the Mac woke.
    var onChange: [@MainActor () -> Void] = []

    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: (any NSObjectProtocol)?
    private var pending: Task<Void, Never>?

    init() {
        watchDevices()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
    }

    var keyboards: [IOHIDServiceClient] { HIDServices.services(client, usage: kHIDUsage_GD_Keyboard) }
    var pointers: [IOHIDServiceClient] {
        HIDServices.services(client, usage: kHIDUsage_GD_Mouse) + HIDServices.services(client, usage: kHIDUsage_GD_Pointer)
    }

    /// Services conforming to a generic desktop usage. Karabiner's virtual devices replay
    /// already-remapped input, so they're left alone. Also used off the main thread.
    nonisolated static func services(_ client: IOHIDEventSystemClient, usage: Int) -> [IOHIDServiceClient] {
        let services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
        return services.filter { service in
            IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(usage)) != 0
                && !name(service).contains("Karabiner")
        }
    }

    nonisolated static func name(_ service: IOHIDServiceClient) -> String {
        property(service, kIOHIDProductKey) ?? ""
    }

    nonisolated static func property<T>(_ service: IOHIDServiceClient, _ key: String) -> T? {
        IOHIDServiceClientCopyProperty(service, key as CFString) as? T
    }

    static func registryID(_ service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    static func matches(_ match: DeviceMatch?, _ service: IOHIDServiceClient) -> Bool {
        guard let match else { return true }
        return match.matches(name: name(service), vendor: property(service, kIOHIDVendorIDKey),
                             product: property(service, kIOHIDProductIDKey))
    }

    // MARK: - Hot plug

    private func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
            { refcon, iterator in
                HIDServices.drain(iterator)
                guard let refcon else { return }
                let services = Unmanaged<HIDServices>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { services.scheduleChange() }
            },
            refcon, &iterator
        )
        if result == KERN_SUCCESS { HIDServices.drain(iterator) } // arms the notification
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    /// The HID event system publishes a new service shortly after IOKit does: wait a bit.
    private func scheduleChange() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            for handler in self.onChange { handler() }
        }
    }
}
