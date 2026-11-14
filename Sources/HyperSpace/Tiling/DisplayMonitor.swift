import CoreGraphics
import Foundation

/// Notices displays that are still connected but show nothing: asleep (standby) or switched
/// to another input, which macOS keeps listing. After `grace` of that, the display counts as
/// unplugged (`ScreenInfo.current(leavingOut:)` leaves it out): its workspaces move to the
/// displays that are left, and come back as soon as it wakes. Polls every few seconds while
/// tiling runs; with a single display a poll is one cheap call and changes nothing. It never
/// takes away every display (the whole Mac asleep is not a display gone).
final class DisplayMonitor {
    /// Displays left out of the layout. Main thread only.
    private(set) var absent: Set<CGDirectDisplayID> = []

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
        if !absent.isEmpty {
            absent.removeAll()
            onChange?()
        }
    }

    private func poll(now: Date = Date()) {
        let displays = Self.onlineDisplays()
        let dark = Set(displays.filter(Self.showsNothing))
        darkSince = darkSince.filter { dark.contains($0.key) }
        for id in dark where darkSince[id] == nil { darkSince[id] = now }
        let absent = Self.absentDisplays(previous: absent, displays: displays, darkSince: darkSince, now: now)
        guard absent != self.absent else { return }
        log.info("displays left out: \(absent.sorted(), privacy: .public)")
        self.absent = absent
        onChange?()
    }

    /// The displays to leave out, given those left out so far (`previous`) and since when each
    /// dark display (asleep or inactive) of `displays` has been dark (`darkSince`):
    /// - a display awake again is back at once;
    /// - one dark for `grace` is left out, unless every display is dark (the Mac itself
    ///   sleeps: nothing is to move anywhere), which leaves the choice as it was.
    static func absentDisplays(previous: Set<CGDirectDisplayID>, displays: [CGDirectDisplayID],
                               darkSince: [CGDirectDisplayID: Date], now: Date,
                               grace: TimeInterval = grace) -> Set<CGDirectDisplayID> {
        let dark = Set(displays.filter { darkSince[$0] != nil })
        var absent = previous.intersection(dark)
        if dark.count < displays.count {
            absent.formUnion(dark.filter { id in darkSince[id].map { now.timeIntervalSince($0) >= grace } ?? false })
        }
        return absent
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
