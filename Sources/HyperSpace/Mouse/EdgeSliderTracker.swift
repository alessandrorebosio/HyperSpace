/// One finger on a trackpad, in the trackpad's normalized coordinates: x from the left edge
/// (0) to the right one (1), y from the bottom (0) to the top (1).
struct EdgeTouch: Equatable {
    let id: Int32
    let x: Float
    let y: Float
}

/// A step of an edge slider: its action, one notch up (or right, on the top and bottom
/// edges) or down (or left).
struct EdgeStep: Equatable {
    let action: EdgeAction
    let up: Bool
}

/// Recognizes the edge sliders in the frames of one trackpad. Pure: frames in, steps out.
///
/// A single finger put down in the band along an edge with an action is a slider from the
/// start: the pointer is held still (`holding`) while it is down, and every `step` it moves
/// along that edge (up and down on the left and right edges, sideways on the top and bottom
/// ones) is one notch. Moving across the edge before the first notch makes it an ordinary
/// pointer move: the hold lifts and the finger is ignored until it is lifted. In a corner,
/// where two bands meet, the direction that reaches a notch first picks the slider. A finger
/// that starts elsewhere is ignored, and so is everything while a second finger is down (a
/// scroll, a click with two fingers) or the trackpad is pressed (a click-drag), until every
/// finger is lifted.
struct EdgeSliderTracker {
    /// Width of the left and right bands, as a share of the trackpad's width.
    static let edgeWidth: Float = 0.05
    /// Height of the top and bottom bands, as a share of the trackpad's height: thinner than
    /// the side ones, since pointer moves often start near the bottom.
    static let edgeHeight: Float = 0.05
    /// Length of one notch on the left and right edges, as a share of the trackpad's height:
    /// the full height is about 8 notches.
    static let step: Float = 0.12
    /// Length of one notch on the top and bottom edges, as a share of the trackpad's width
    /// (wider than it is tall: about the same distance as a notch on the sides).
    static let horizontalStep: Float = 0.09
    /// Movement across the edge, as a share of the trackpad, that makes a finger a pointer move.
    static let maxDrift: Float = 0.05

    enum Side { case left, right, top, bottom }

    var left: EdgeAction
    var right: EdgeAction
    var top: EdgeAction
    var bottom: EdgeAction

    private struct Slider {
        let id: Int32
        /// The left or right edge the finger started on (with an action), if any.
        let vertical: Side?
        /// The top or bottom edge the finger started on (with an action), if any.
        let horizontal: Side?
        let startX: Float
        let startY: Float
        /// Set by the first notch: the edge it slides along, and where the last notch was.
        var side: Side?
        var anchor: Float = 0
    }

    private var slider: Slider?
    /// Set until every finger is lifted: the fingers down are not a slider.
    private var ignoring = false

    init(left: EdgeAction, right: EdgeAction, top: EdgeAction = .none, bottom: EdgeAction = .none) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    /// Whether a slider is in progress: the pointer is held still meanwhile.
    var holding: Bool { slider != nil }

    /// Takes one frame of the trackpad, as the number of fingers on it and the first of them
    /// (only a lone finger matters, so a frame needs no array), and whether the trackpad is
    /// pressed; returns the notches it crossed.
    mutating func update(first: EdgeTouch?, count: Int, pressed: Bool = false) -> [EdgeStep] {
        guard count > 0, let touch = first else {
            slider = nil
            ignoring = false
            return []
        }
        guard count == 1, !pressed, !ignoring else {
            slider = nil
            ignoring = true
            return []
        }
        guard var current = slider, current.id == touch.id else {
            // A new finger: a slider only when it lands in a band that does something.
            let vertical: Side? = touch.x < Self.edgeWidth ? .left : touch.x > 1 - Self.edgeWidth ? .right : nil
            let horizontal: Side? = touch.y < Self.edgeHeight ? .bottom : touch.y > 1 - Self.edgeHeight ? .top : nil
            let v = vertical.flatMap { action($0) != .none ? $0 : nil }
            let h = horizontal.flatMap { action($0) != .none ? $0 : nil }
            guard v != nil || h != nil else {
                slider = nil
                ignoring = true
                return []
            }
            slider = Slider(id: touch.id, vertical: v, horizontal: h, startX: touch.x, startY: touch.y)
            return []
        }
        if current.side == nil {
            let dx = abs(touch.x - current.startX), dy = abs(touch.y - current.startY)
            if let v = current.vertical, dy >= Self.step, current.horizontal == nil || dy / Self.step >= dx / Self.horizontalStep {
                current.side = v
                current.anchor = current.startY
            } else if let h = current.horizontal, dx >= Self.horizontalStep {
                current.side = h
                current.anchor = current.startX
            } else if (current.horizontal == nil && dx > Self.maxDrift) || (current.vertical == nil && dy > Self.maxDrift) {
                // Across the only edge it could slide along: a pointer move.
                slider = nil
                ignoring = true
                return []
            } else {
                slider = current
                return []
            }
        }
        guard let side = current.side else { return [] }
        let along = side == .left || side == .right
        let position = along ? touch.y : touch.x
        let step = along ? Self.step : Self.horizontalStep
        var steps: [EdgeStep] = []
        let action = action(side)
        while position - current.anchor >= step {
            current.anchor += step
            steps.append(EdgeStep(action: action, up: true))
        }
        while current.anchor - position >= step {
            current.anchor -= step
            steps.append(EdgeStep(action: action, up: false))
        }
        slider = current
        return steps
    }

    private func action(_ side: Side) -> EdgeAction {
        switch side {
        case .left: return left
        case .right: return right
        case .top: return top
        case .bottom: return bottom
        }
    }
}

/// Recognizes a double tap with one finger in a corner of one trackpad. Pure: frames in,
/// corners out.
///
/// A tap is a finger put down in a corner with an action and lifted soon, having barely moved;
/// two taps in the same corner close together are a double tap. The pointer is held still
/// while a finger is down in such a corner (`holding`), and the clicks a tap makes with tap to
/// click are dropped meanwhile and just after (see `EdgeSliders`). Anything else (a finger
/// elsewhere, a second finger, a press, a long touch, a move) is not a tap and starts over.
struct CornerTapTracker {
    /// Size of each corner, as a share of the trackpad's width and height.
    static let cornerWidth: Float = 0.12
    static let cornerHeight: Float = 0.18
    /// The longest a tap's finger stays down, in seconds.
    static let maxTapDuration: Double = 0.3
    /// The longest from the first tap's lift to the second tap's touch, in seconds.
    static let maxGap: Double = 0.4
    /// Movement, as a share of the trackpad, that makes a finger something other than a tap.
    static let maxDrift: Float = 0.03

    /// The corners with an action.
    var corners: Set<TrackpadCorner>

    private struct Touch {
        let id: Int32
        let corner: TrackpadCorner
        let x: Float
        let y: Float
        let start: Double
    }

    private var touch: Touch?
    private var ignoring = false
    /// The last tap, waiting for a second one.
    private var lastTap: (corner: TrackpadCorner, end: Double)?

    init(corners: Set<TrackpadCorner>) {
        self.corners = corners
    }

    /// Whether a finger is down in a corner with an action, as a tap so far.
    var holding: Bool { touch != nil }

    /// The corner a point is in, if any.
    static func corner(x: Float, y: Float) -> TrackpadCorner? {
        let left = x < cornerWidth, right = x > 1 - cornerWidth
        let bottom = y < cornerHeight, top = y > 1 - cornerHeight
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: return nil
        }
    }

    /// Takes one frame (see `EdgeSliderTracker.update`) at `time`, in seconds; returns the
    /// corner double-tapped, if this frame ends a double tap.
    mutating func update(first: EdgeTouch?, count: Int, pressed: Bool = false, time: Double) -> TrackpadCorner? {
        guard count > 0, let finger = first else {
            defer { touch = nil; ignoring = false }
            guard let tap = touch, time - tap.start <= Self.maxTapDuration else {
                if touch != nil { lastTap = nil }
                return nil
            }
            if let last = lastTap, last.corner == tap.corner, tap.start - last.end <= Self.maxGap {
                lastTap = nil
                return tap.corner
            }
            lastTap = (tap.corner, time)
            return nil
        }
        guard count == 1, !pressed, !ignoring else { return cancel() }
        guard let current = touch, current.id == finger.id else {
            guard touch == nil, let corner = Self.corner(x: finger.x, y: finger.y), corners.contains(corner) else {
                return cancel()
            }
            if let last = lastTap, time - last.end > Self.maxGap { lastTap = nil }
            touch = Touch(id: finger.id, corner: corner, x: finger.x, y: finger.y, start: time)
            return nil
        }
        if abs(finger.x - current.x) > Self.maxDrift || abs(finger.y - current.y) > Self.maxDrift
            || time - current.start > Self.maxTapDuration {
            return cancel()
        }
        return nil
    }

    private mutating func cancel() -> TrackpadCorner? {
        touch = nil
        ignoring = true
        lastTap = nil
        return nil
    }
}
