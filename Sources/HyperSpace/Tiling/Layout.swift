import AppKit

/// Pure layout math. All rects are in global top-left ("AX") coordinates.
enum Layout {
    /// One frame per weight. Weights size the windows that share a split (the stack,
    /// or all columns); the master's size comes from `ratio`. `focused` and `peek` are for
    /// the accordion: the focused window in front, the others showing `peek` points beside it.
    static func frames(_ kind: LayoutKind, weights: [CGFloat], in area: CGRect, gap: CGFloat, ratio: CGFloat,
                       focused: Int = 0, peek: CGFloat = 0) -> [CGRect] {
        let count = weights.count
        guard count > 0 else { return [] }
        switch kind {
        case .monocle:
            return Array(repeating: area, count: count)
        case .accordion:
            return accordion(count: count, focused: min(max(0, focused), count - 1), in: area, peek: peek)
        case .columns:
            return split(area, weights: weights, horizontally: true, gap: gap)
        case .tall, .wide:
            guard count > 1 else { return [area] }
            let horizontal = kind == .tall
            let length = horizontal ? area.width : area.height
            let master = ((length - gap) * ratio).rounded()
            let (masterRect, rest) = area.divided(atDistance: master, from: horizontal ? .minXEdge : .minYEdge)
            let stack = horizontal
                ? CGRect(x: rest.minX + gap, y: rest.minY, width: rest.width - gap, height: rest.height)
                : CGRect(x: rest.minX, y: rest.minY + gap, width: rest.width, height: rest.height - gap)
            return [masterRect] + split(stack, weights: Array(weights.dropFirst()), horizontally: !horizontal, gap: gap)
        }
    }

    /// Windows on top of each other, all the same size: the ones before the focused window
    /// line up on the left edge and the ones after it on the right edge, so `peek` points of
    /// the nearest neighbour stay visible on each side of the focused one.
    static func accordion(count: Int, focused: Int, in area: CGRect, peek: CGFloat) -> [CGRect] {
        guard count > 1 else { return [area] }
        let peek = min(max(0, peek), (area.width / 4).rounded(.down))
        let before = focused > 0 ? peek : 0
        let after = focused < count - 1 ? peek : 0
        let width = area.width - before - after
        return (0..<count).map { i in
            let x = i < focused ? area.minX : i > focused ? area.maxX - width : area.minX + before
            return CGRect(x: x, y: area.minY, width: width, height: area.height)
        }
    }

    static func split(_ rect: CGRect, weights: [CGFloat], horizontally: Bool, gap: CGFloat) -> [CGRect] {
        let length = horizontally ? rect.width : rect.height
        let usable = length - gap * CGFloat(weights.count - 1)
        let total = weights.reduce(0, +)
        var offset: CGFloat = 0
        return weights.enumerated().map { i, weight in
            // The last tile absorbs rounding so the edge stays flush.
            let extent = i == weights.count - 1 ? length - offset : (usable * weight / total).rounded(.down)
            defer { offset += extent + gap }
            return horizontally
                ? CGRect(x: rect.minX + offset, y: rect.minY, width: extent, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: extent)
        }
    }

    /// Closest rect in `direction`, preferring ones that overlap on the perpendicular axis.
    static func neighbor<T>(of origin: CGRect, _ direction: Direction, among candidates: [(T, CGRect)]) -> T? {
        let from = origin.center
        var best: (T, CGFloat)?
        for (item, rect) in candidates {
            let to = rect.center
            let primary: CGFloat
            let overlaps: Bool
            switch direction {
            case .left: primary = from.x - to.x; overlaps = rect.minY < origin.maxY && rect.maxY > origin.minY
            case .right: primary = to.x - from.x; overlaps = rect.minY < origin.maxY && rect.maxY > origin.minY
            case .up: primary = from.y - to.y; overlaps = rect.minX < origin.maxX && rect.maxX > origin.minX
            case .down: primary = to.y - from.y; overlaps = rect.minX < origin.maxX && rect.maxX > origin.minX
            }
            guard primary > 1 else { continue }
            let secondary = (direction == .left || direction == .right) ? abs(to.y - from.y) : abs(to.x - from.x)
            let score = overlaps ? primary : primary + secondary + 100_000
            if best == nil || score < best!.1 { best = (item, score) }
        }
        return best?.0
    }
}

struct ScreenInfo {
    let id: CGDirectDisplayID
    let frame: CGRect
    /// `NSScreen.visibleFrame` (no menu bar, no Dock), flipped: the only area windows are laid out in.
    let visible: CGRect

    /// Screens in a stable order: the main display (with the menu bar) first, then the
    /// others left to right. NSScreen uses bottom-left coordinates; AX and CGWindowList top-left,
    /// with the origin at the top-left of the main display, so every frame is flipped against it.
    /// Displays asleep or showing another input for a while (`DisplayMonitor`) are left out,
    /// as if unplugged, as long as one display remains.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        let all = screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return ScreenInfo(id: id, frame: flip(screen.frame), visible: flip(screen.visibleFrame))
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
        let fitted = CGSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
        return CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

extension Array where Element == ScreenInfo {
    func index(for rect: CGRect) -> Int {
        let center = rect.center
        if let i = firstIndex(where: { $0.frame.contains(center) }) { return i }
        return indices.min { self[$0].frame.center.distance(to: center) < self[$1].frame.center.distance(to: center) } ?? 0
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
