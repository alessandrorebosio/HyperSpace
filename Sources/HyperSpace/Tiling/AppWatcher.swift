import AppKit
import ApplicationServices

/// AX observer for one running application. Notifications are delivered on the
/// main run loop; nothing is polled.
final class AppWatcher {
    let pid: pid_t
    let bundleID: String?
    let element: AXUIElement
    private let observer: AXObserver
    private let refcon: UnsafeMutableRawPointer

    /// Fails while the app is still launching (AX not ready yet); the caller retries.
    init?(app: NSRunningApplication, refcon: UnsafeMutableRawPointer) {
        pid = app.processIdentifier
        bundleID = app.bundleIdentifier
        element = AXUIElementCreateApplication(pid)
        self.refcon = refcon
        // A hung app must not freeze the window manager for long.
        AXUIElementSetMessagingTimeout(element, 0.5)

        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let created else { return nil }
        observer = created

        let notifications = [kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
        var registered = false
        for name in notifications where AXObserverAddNotification(observer, element, name as CFString, refcon) == .success {
            registered = true
        }
        guard registered else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    var windows: [AXUIElement] {
        AX.elements(element, kAXWindowsAttribute)
    }

    func watchDestroyed(_ window: AXUIElement) {
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    func invalidate() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
        .handle(notification as String, element: element)
}
