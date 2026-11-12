import AppKit

struct ScreenInfo {
    let id: CGDirectDisplayID
    let frame: CGRect
    /// `NSScreen.visibleFrame` (no menu bar, no Dock), flipped: the only area windows are laid out in.
    let visible: CGRect
    /// The monitor's name ("LG UltraFine", "Built-in Retina Display").
    var name = ""

    /// Screens in a stable order: the main display (with the menu bar) first, then the
    /// others left to right. NSScreen uses bottom-left coordinates; AX and CGWindowList top-left,
    /// with the origin at the top-left of the main display, so every frame is flipped against it.
    /// Displays asleep or showing another input for a while (`DisplayMonitor`) are left out,
    /// as if unplugged, as long as one display remains.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        let all = screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return ScreenInfo(id: id, frame: flipped(screen.frame, height: height),
                              visible: flipped(screen.visibleFrame, height: height), name: screen.localizedName)
        }
        let present = all.filter { !DisplayMonitor.absent.contains($0.id) }
        return (present.isEmpty ? all : present)
        .enumerated()
        .sorted { a, b in
            if (a.offset == 0) != (b.offset == 0) { return a.offset == 0 }
            return (a.element.frame.minX, a.element.frame.minY) < (b.element.frame.minX, b.element.frame.minY)
        }
        .map(\.element)
    }
}

extension ScreenInfo {
    /// Height of the main display: AppKit's bottom-left coordinates and the top-left ones of AX
    /// and CGEvent mirror each other around it.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Between AppKit's bottom-left coordinates and the top-left ones of AX and CGEvent (the
    /// flip is its own inverse), against the main display's height.
    static func flipped(_ rect: CGRect, height: CGFloat = primaryHeight) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func flipped(_ point: CGPoint, height: CGFloat = primaryHeight) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    /// The display's UUID: unlike its id, the same every time the monitor is plugged in.
    var uuid: String { Self.uuid(of: id) }

    private static var uuids: [CGDirectDisplayID: String] = [:]

    static func uuid(of id: CGDirectDisplayID) -> String {
        if let uuid = uuids[id] { return uuid }
        guard let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, ref) as String? else { return String(id) }
        uuids[id] = text
        return text
    }

    /// `rect` moved from this display to `other`, keeping its position and size as shares
    /// of the visible area (a window at the left third, half as wide, stays so).
    func relocate(_ rect: CGRect, to other: ScreenInfo) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return other.centered(rect.size) }
        let sx = other.visible.width / visible.width
        let sy = other.visible.height / visible.height
        let width = min(other.visible.width, (rect.width * sx).rounded())
        let height = min(other.visible.height, (rect.height * sy).rounded())
        let x = other.visible.minX + ((rect.minX - visible.minX) * sx).rounded()
        let y = other.visible.minY + ((rect.minY - visible.minY) * sy).rounded()
        return CGRect(x: min(max(x, other.visible.minX), other.visible.maxX - width),
                      y: min(max(y, other.visible.minY), other.visible.maxY - height), width: width, height: height)
    }

    /// A frame of `size` (shrunk to fit) centered in the visible area.
    func centered(_ size: CGSize) -> CGRect {
        visible.centered(CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height)))
    }
}

extension ScreenInfo {
    /// The display a workspace pinned to `pin` lives on, among `screens` (in `current()`
    /// order): "main" is the first; a number n the n-th; otherwise the display with that UUID,
    /// else the one with that name, else the one whose name contains it (case-insensitive).
    /// Nil when no such display is connected.
    static func pinned(_ pin: String, among screens: [ScreenInfo]) -> ScreenInfo? {
        let text = pin.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !screens.isEmpty else { return nil }
        if text.lowercased() == "main" { return screens.first }
        if let number = Int(text) { return screens.indices.contains(number - 1) ? screens[number - 1] : nil }
        if let screen = screens.first(where: { $0.uuid.caseInsensitiveCompare(text) == .orderedSame }) { return screen }
        if let screen = screens.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return screen }
        return screens.first { !$0.name.isEmpty && $0.name.range(of: text, options: .caseInsensitive) != nil }
    }

    /// What Settings writes to pin a workspace to this display: its name, or its UUID when
    /// another connected display has the same name (two identical monitors).
    func pinValue(among screens: [ScreenInfo]) -> String {
        let twins = screens.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return name.isEmpty || twins.count > 1 ? uuid : name
    }
}

extension Array where Element == ScreenInfo {
    /// The display `rect` is on, or nil when there is no display.
    func screen(for rect: CGRect) -> ScreenInfo? {
        isEmpty ? nil : self[index(for: rect)]
    }

    /// The display with this id, if it is among them.
    func first(id: CGDirectDisplayID) -> ScreenInfo? {
        first { $0.id == id }
    }

    /// The display after the one with this id, wrapping around (in `ScreenInfo.current()` order).
    func next(after id: CGDirectDisplayID) -> ScreenInfo? {
        guard let index = firstIndex(where: { $0.id == id }) else { return nil }
        return self[(index + 1) % count]
    }

    /// The display next to the one with this id in a direction: the nearest one lying wholly
    /// beyond its edge, the best-aligned first. Nil when there is none that way.
    func neighbor(of id: CGDirectDisplayID, _ direction: Direction) -> ScreenInfo? {
        guard let from = first(id: id)?.frame else { return nil }
        let candidates = filter { other in
            guard other.id != id else { return false }
            switch direction {
            case .left: return other.frame.maxX <= from.minX + 1
            case .right: return other.frame.minX >= from.maxX - 1
            case .up: return other.frame.maxY <= from.minY + 1
            case .down: return other.frame.minY >= from.maxY - 1
            }
        }
        func score(_ frame: CGRect) -> (CGFloat, CGFloat) {
            let horizontal = direction == .left || direction == .right
            let gap = horizontal ? abs(frame.center.x - from.center.x) : abs(frame.center.y - from.center.y)
            let offset = horizontal ? abs(frame.center.y - from.center.y) : abs(frame.center.x - from.center.x)
            return (gap, offset)
        }
        return candidates.min { score($0.frame) < score($1.frame) }
    }

    func index(for rect: CGRect) -> Int {
        let center = rect.center
        if let i = firstIndex(where: { $0.frame.contains(center) }) { return i }
        return indices.min { self[$0].frame.center.distance(to: center) < self[$1].frame.center.distance(to: center) } ?? 0
    }
}
