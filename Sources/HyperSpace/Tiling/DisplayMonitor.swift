import CoreGraphics
import Foundation

/// Notices displays that are still connected but show nothing: asleep (standby) or switched
/// to another input, which macOS keeps listing. After `grace` of that, the display counts as
/// unplugged (`ScreenInfo.current()` leaves it out): its workspaces move to the displays that
/// are left, and come back as soon as it wakes. Polls only while several displays are connected,
/// and never takes away every display (the whole Mac asleep is not a display gone).
final class DisplayMonitor {
    /// Displays left out of the layout. Main thread only.
    private(set) static var absent: Set<CGDirectDisplayID> = []

    static let grace: TimeInterval = 60
    static let interval: TimeInterval = 5

    /// Called when a display is left out or comes back.
    var onChange: (() -> Void)?

    private var timer: Timer?
    /// Since when each display has shown nothing.
    private var darkSince: [CGDirectDisplayID: Date] = [:]

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        darkSince.removeAll()
        if !Self.absent.isEmpty {
            Self.absent.removeAll()
            onChange?()
        }
    }

    private func poll(now: Date = Date()) {
        let displays = Self.onlineDisplays()
        let dark = Set(displays.filter(Self.showsNothing))
        darkSince = darkSince.filter { dark.contains($0.key) }
        for id in dark where darkSince[id] == nil { darkSince[id] = now }

        var absent = Self.absent.intersection(displays)
        absent.subtract(displays.filter { !dark.contains($0) })
        // With every display dark the Mac itself sleeps: nothing to move anywhere.
        if dark.count < displays.count {
            for (id, since) in darkSince where now.timeIntervalSince(since) >= Self.grace { absent.insert(id) }
        }
        guard absent != Self.absent else { return }
        log.info("displays left out: \(absent.sorted(), privacy: .public)")
        Self.absent = absent
        onChange?()
    }

    private static func showsNothing(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 1 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        // Mirrored displays show the same picture as their main one.
        return Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }
}
