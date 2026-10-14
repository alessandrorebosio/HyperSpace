import AppKit
import ApplicationServices

/// L2: how expensive is reading window state through AX, sequentially vs per app in parallel,
/// compared with a single CGWindowList snapshot.
enum AXSpike {
    struct AppWindows {
        let name: String
        let count: Int
        let error: AXError
        let ms: Double
    }

    static func run() {
        print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else { return }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        let t0 = Date()
        let sequential = apps.map(read)
        let sequentialMs = Date().timeIntervalSince(t0) * 1000

        for r in sequential.sorted(by: { $0.ms > $1.ms }) {
            print(String(format: "  %-28@ %2d window(s)  %7.2f ms  %@", r.name as NSString, r.count, r.ms,
                         r.error == .success ? "" : "AXError \(r.error.rawValue)"))
        }

        let t1 = Date()
        DispatchQueue.concurrentPerform(iterations: apps.count) { _ = read(apps[$0]) }
        let parallelMs = Date().timeIntervalSince(t1) * 1000

        let t2 = Date()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let cgMs = Date().timeIntervalSince(t2) * 1000

        let total = sequential.reduce(0) { $0 + $1.count }
        print(String(format: "\n%d apps, %d AX windows", apps.count, total))
        print(String(format: "AX sequential:        %7.2f ms", sequentialMs))
        print(String(format: "AX parallel per app:  %7.2f ms", parallelMs))
        print(String(format: "CGWindowList (%3d):   %7.2f ms  (frames only, no permission)", list.count, cgMs))
    }

    static func read(_ app: NSRunningApplication) -> AppWindows {
        let start = Date()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        let windows = value as? [AXUIElement] ?? []
        for window in windows {
            var position: CFTypeRef?
            var size: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
        }
        return AppWindows(name: app.localizedName ?? "?", count: windows.count, error: error,
                          ms: Date().timeIntervalSince(start) * 1000)
    }
}
