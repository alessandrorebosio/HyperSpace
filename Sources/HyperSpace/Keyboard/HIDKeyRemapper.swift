import Foundation

/// Simple 1:1 key remaps (and the hyper key carrier) are pushed to the HID driver
/// with `hidutil`. They are applied in the kernel's HID layer, so they cost
/// zero CPU at runtime and need no permission at all.
final class HIDKeyRemapper {
    private let queue = DispatchQueue(label: "HyperSpace.hidutil", qos: .utility)
    /// nil until the first apply, so a mapping left over from a crash is always replaced.
    private var current: [HIDRemap]?

    func apply(_ remaps: [HIDRemap]) {
        guard remaps != current else { return }
        current = remaps
        let json = Self.json(remaps)
        queue.async { Self.run(json) }
    }

    /// Restores the default keyboard on quit.
    func reset() {
        guard let current, !current.isEmpty else { return }
        self.current = []
        queue.sync { Self.run(Self.json([])) }
    }

    private static func json(_ remaps: [HIDRemap]) -> String {
        let page: UInt64 = 0x7_0000_0000
        let items = remaps.map {
            "{\"HIDKeyboardModifierMappingSrc\":\(page | UInt64($0.from)),\"HIDKeyboardModifierMappingDst\":\(page | UInt64($0.to))}"
        }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }

    private static func run(_ json: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("hidutil failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
