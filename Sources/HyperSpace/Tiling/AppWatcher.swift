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

        let notifications = [kAXWindowCreatedNotification, kAXWindowMiniaturizedNotification,
                             kAXWindowDeminiaturizedNotification, kAXFocusedWindowChangedNotification]
        var registered = false
        var failure = AXError.success
        for name in notifications {
            let result = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if result == .success { registered = true } else { failure = result }
        }
        guard registered else {
            log.debug("watch \(app.bundleIdentifier ?? "?", privacy: .public) failed: AX error \(failure.rawValue)")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    var windows: [AXUIElement] {
        AX.elements(element, kAXWindowsAttribute)
    }

    /// Per-window notifications: closed, moved or resized (by hand, to snap it back), and
    /// retitled (for title floating rules).
    func watch(_ window: AXUIElement) {
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, refcon)
        }
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
