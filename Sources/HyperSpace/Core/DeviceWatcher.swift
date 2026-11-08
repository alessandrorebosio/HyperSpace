import AppKit
import IOKit

/// Calls `onChange` on the main thread when an IOKit service of a class appears (a keyboard or a
/// trackpad connected over USB or Bluetooth, or reconnected) and when the Mac wakes. Nothing is
/// polled: IOKit match notifications. Watching stops when the watcher is released.
final class DeviceWatcher {
    private let onChange: () -> Void
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var wakeObserver: NSObjectProtocol?

    init(matching serviceClass: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            IONotificationPortSetDispatchQueue(port, .main)
            let result = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, IOServiceMatching(serviceClass),
                { refcon, iterator in
                    DeviceWatcher.drain(iterator)
                    guard let refcon else { return }
                    Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange()
                },
                Unmanaged.passUnretained(self).toOpaque(), &iterator
            )
            // The notification only arms once the iterator has been drained.
            if result == KERN_SUCCESS { Self.drain(iterator) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onChange() }
    }

    deinit {
        if iterator != 0 { IOObjectRelease(iterator) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
