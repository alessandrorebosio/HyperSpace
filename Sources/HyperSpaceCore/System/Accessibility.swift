import ApplicationServices
import Foundation

/// The single TCC permission HyperSpace needs. macOS posts `com.apple.accessibility.api` when the
/// Accessibility list changes, but not reliably to every process, so while the permission is
/// missing we also re-check every 2 s. Once granted, nothing runs.
@MainActor
public final class Accessibility {
    public private(set) var isGranted = AXIsProcessTrusted()
    public var onChange: ((Bool) -> Void)? {
        didSet { updatePolling() }
    }
    private var observer: (any NSObjectProtocol)?
    private var poll: Task<Void, Never>?

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

    /// Adds HyperSpace to the Accessibility list and shows the system prompt (first time only).
    public func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func refresh() {
        let granted = AXIsProcessTrusted()
        guard granted != isGranted else { return }
        isGranted = granted
        updatePolling()
        onChange?(granted)
    }

    private func updatePolling() {
        if isGranted {
            poll?.cancel()
            poll = nil
        } else if poll == nil {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    self?.refresh()
                }
            }
        }
    }
}
