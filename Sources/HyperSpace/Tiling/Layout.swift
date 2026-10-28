import AppKit

/// Pure layout math. All rects are in global top-left ("AX") coordinates.
enum Layout {
    /// One frame per weight. Weights size the windows that share a split (the stack,
    /// or all columns); the master's size comes from `ratio`.
    static func frames(_ kind: LayoutKind, weights: [CGFloat], in area: CGRect, gap: CGFloat, ratio: CGFloat) -> [CGRect] {
        let count = weights.count
        guard count > 0 else { return [] }
        switch kind {
        case .monocle:
            return Array(repeating: area, count: count)
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

    private static func split(_ rect: CGRect, weights: [CGFloat], horizontally: Bool, gap: CGFloat) -> [CGRect] {
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
    let visible: CGRect

    /// Screens ordered left to right (then top to bottom): the first is the leftmost.
    /// NSScreen uses bottom-left coordinates; AX and CGWindowList use top-left.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        return screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return ScreenInfo(id: id, frame: flip(screen.frame), visible: flip(screen.visibleFrame))
        }
        .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
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
