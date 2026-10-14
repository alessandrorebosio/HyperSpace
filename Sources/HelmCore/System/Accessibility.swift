import ApplicationServices
import Foundation

/// The single TCC permission Helm needs. Tracks changes without polling: macOS posts
/// `com.apple.accessibility.api` whenever the Accessibility list changes.
@MainActor
public final class Accessibility {
    public private(set) var isGranted = AXIsProcessTrusted()
    public var onChange: ((Bool) -> Void)?
    private var observer: (any NSObjectProtocol)?

    public init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust value is updated shortly after the notification is posted.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Adds Helm to the Accessibility list and shows the system prompt (first time only).
    public func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func refresh() {
        let granted = AXIsProcessTrusted()
        guard granted != isGranted else { return }
        isGranted = granted
        onChange?(granted)
    }
}
