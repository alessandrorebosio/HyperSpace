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
        // Degenerate weights (all zero) would divide by zero: split evenly instead.
        let sum = weights.reduce(0, +)
        let weights = sum > 0 ? weights : weights.map { _ in 1 }
        let total = sum > 0 ? sum : CGFloat(weights.count)
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

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// A rect of `size` with the same center as this one; `rounded` puts its origin on whole points.
    func centered(_ size: CGSize, rounded: Bool = false) -> CGRect {
        let x = midX - size.width / 2
        let y = midY - size.height / 2
        return CGRect(origin: rounded ? CGPoint(x: x.rounded(), y: y.rounded()) : CGPoint(x: x, y: y), size: size)
    }

    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        origin.isClose(to: other.origin, tolerance: tolerance) && size.isClose(to: other.size, tolerance: tolerance)
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }

    /// Both coordinates within `tolerance` points.
    func isClose(to other: CGPoint, tolerance: CGFloat) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}

extension CGSize {
    /// Both dimensions within `tolerance` points.
    func isClose(to other: CGSize, tolerance: CGFloat) -> Bool {
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
