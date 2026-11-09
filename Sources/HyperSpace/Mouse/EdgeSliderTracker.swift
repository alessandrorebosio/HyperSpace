/// One finger on a trackpad, in the trackpad's normalized coordinates: x from the left edge
/// (0) to the right one (1), y from the bottom (0) to the top (1).
struct EdgeTouch: Equatable {
    let id: Int32
    let x: Float
    let y: Float
}

/// A step of an edge slider: its action, one notch up or down.
struct EdgeStep: Equatable {
    let action: EdgeAction
    let up: Bool
}

/// Recognizes the edge sliders in the frames of one trackpad. Pure: frames in, steps out.
///
/// A single finger put down in the band along the left or right edge (an edge with an action)
/// is a slider from the start: the pointer is held still (`holding`) while it is down, and
/// every `step` of the trackpad's height it moves up or down is one notch. Moving sideways
/// before the first notch makes it an ordinary pointer move: the hold lifts and the finger is
/// ignored until it is lifted. So is any finger that starts elsewhere, and a second finger
/// (a scroll, a click with two fingers) ends the slider until every finger is lifted.
struct EdgeSliderTracker {
    /// Width of each edge band, as a share of the trackpad's width.
    static let edgeWidth: Float = 0.08
    /// Height of one notch, as a share of the trackpad's height: the full height is 20.
    static let step: Float = 0.05
    /// Sideways movement, as a share of the width, that makes a finger a pointer move.
    static let maxDrift: Float = 0.05

    enum Side { case left, right }

    var left: EdgeAction
    var right: EdgeAction

    private struct Slider {
        let id: Int32
        let side: Side
        let startX: Float
        var anchorY: Float
        var moved = false
    }

    private var slider: Slider?
    /// Set until every finger is lifted: the fingers down are not a slider.
    private var ignoring = false

    init(left: EdgeAction, right: EdgeAction) {
        self.left = left
        self.right = right
    }

    /// Whether a slider is in progress: the pointer is held still meanwhile.
    var holding: Bool { slider != nil }

    /// Takes the fingers on the trackpad in one frame; returns the notches it crossed.
    mutating func update(_ touches: [EdgeTouch]) -> [EdgeStep] {
        update(first: touches.first, count: touches.count)
    }

    /// The same from the number of fingers and the first of them: only a lone finger matters,
    /// so a frame needs no array of its fingers.
    mutating func update(first: EdgeTouch?, count: Int) -> [EdgeStep] {
        guard count > 0, let touch = first else {
            slider = nil
            ignoring = false
            return []
        }
        guard count == 1, !ignoring else {
            slider = nil
            ignoring = true
            return []
        }
        guard var current = slider, current.id == touch.id else {
            // A new finger: a slider only when it lands in a band that does something.
            let side: Side? = touch.x < Self.edgeWidth ? .left : touch.x > 1 - Self.edgeWidth ? .right : nil
            guard let side, action(side) != .none else {
                slider = nil
                ignoring = true
                return []
            }
            slider = Slider(id: touch.id, side: side, startX: touch.x, anchorY: touch.y)
            return []
        }
        if !current.moved, abs(touch.x - current.startX) > Self.maxDrift {
            slider = nil
            ignoring = true
            return []
        }
        var steps: [EdgeStep] = []
        let action = action(current.side)
        while touch.y - current.anchorY >= Self.step {
            current.anchorY += Self.step
            steps.append(EdgeStep(action: action, up: true))
        }
        while current.anchorY - touch.y >= Self.step {
            current.anchorY -= Self.step
            steps.append(EdgeStep(action: action, up: false))
        }
        if !steps.isEmpty { current.moved = true }
        slider = current
        return steps
    }

    private func action(_ side: Side) -> EdgeAction {
        side == .left ? left : right
    }
}
