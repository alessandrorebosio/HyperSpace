import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct EdgeSliderTests {
    private func touch(_ x: Float, _ y: Float, id: Int32 = 1) -> [EdgeTouch] { [EdgeTouch(id: id, x: x, y: y)] }

    @Test func slideUpAndDownOnTheRightEdge() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        #expect(tracker.update(touch(0.96, 0.50)).isEmpty)
        #expect(tracker.holding)
        #expect(tracker.update(touch(0.96, 0.56)).isEmpty)
        #expect(tracker.update(touch(0.96, 0.63)) == [EdgeStep(action: .volume, up: true)])
        // Two notches in one frame, then two back down.
        #expect(tracker.update(touch(0.96, 0.87)) == Array(repeating: EdgeStep(action: .volume, up: true), count: 2))
        #expect(tracker.update(touch(0.96, 0.61)) == Array(repeating: EdgeStep(action: .volume, up: false), count: 2))
        #expect(tracker.update([]).isEmpty)
        #expect(!tracker.holding)
    }

    @Test func leftEdgeHasItsOwnAction() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        _ = tracker.update(touch(0.03, 0.50))
        #expect(tracker.update(touch(0.03, 0.37)) == [EdgeStep(action: .brightness, up: false)])
    }

    @Test func pointerMovesAreLeftAlone() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        // Starting in the middle.
        _ = tracker.update(touch(0.50, 0.50))
        #expect(!tracker.holding)
        #expect(tracker.update(touch(0.50, 0.70)).isEmpty)
        _ = tracker.update([])
        // Starting on the edge but moving sideways: the hold lifts, nothing follows.
        _ = tracker.update(touch(0.97, 0.50))
        _ = tracker.update(touch(0.90, 0.52))
        #expect(!tracker.holding)
        #expect(tracker.update(touch(0.88, 0.80)).isEmpty)
    }

    @Test func secondFingerEndsTheSlider() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        _ = tracker.update(touch(0.96, 0.50))
        #expect(tracker.update(touch(0.96, 0.50) + touch(0.60, 0.50, id: 2)).isEmpty)
        #expect(!tracker.holding)
        // Still ignored with one finger left, until every finger is lifted.
        #expect(tracker.update(touch(0.96, 0.80)).isEmpty)
        _ = tracker.update([])
        _ = tracker.update(touch(0.96, 0.50))
        #expect(tracker.holding)
    }

    @Test func edgeWithNothingToDoIsNotASlider() {
        var tracker = EdgeSliderTracker(left: .none, right: .volume)
        _ = tracker.update(touch(0.03, 0.50))
        #expect(!tracker.holding)
        #expect(tracker.update(touch(0.03, 0.80)).isEmpty)
    }

    @Test func config() throws {
        let off = try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data("{}".utf8)))
        #expect(off.trackpad == TrackpadConfig())
        #expect(!off.trackpad.isActive)
        let raw = #"{ "trackpad": { "edgeSliders": true, "leftEdge": "Volume", "rightEdge": "none" } }"#
        let on = try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data(raw.utf8)))
        #expect(on.trackpad == TrackpadConfig(edgeSliders: true, leftEdge: .volume, rightEdge: .none))
        #expect(!on.tap.holdsCornerClicks)
        #expect(on.trackpad.isActive)
        // Pointer moves are watched only with the sliders on, to hold the pointer during a slide.
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        #expect(on.tap.holdsPointer && on.tap.eventMask & moved != 0)
        #expect(!off.tap.holdsPointer && off.tap.eventMask & moved == 0)
        let bad = #"{ "trackpad": { "leftEdge": "mute" } }"#
        #expect(throws: ConfigError.self) { try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data(bad.utf8))) }
    }
}

@Suite struct HorizontalEdgeTests {
    private func touch(_ x: Float, _ y: Float, id: Int32 = 1) -> [EdgeTouch] { [EdgeTouch(id: id, x: x, y: y)] }

    @Test func bottomEdgeSeeksSideways() {
        var tracker = EdgeSliderTracker(left: .none, right: .none, bottom: .seek)
        _ = tracker.update(touch(0.50, 0.03))
        #expect(tracker.holding)
        #expect(tracker.update(touch(0.55, 0.04)).isEmpty)
        #expect(tracker.update(touch(0.60, 0.04)) == [EdgeStep(action: .seek, up: true)])
        #expect(tracker.update(touch(0.40, 0.05)) == Array(repeating: EdgeStep(action: .seek, up: false), count: 2))
    }

    @Test func movingUpFromTheBottomIsAPointerMove() {
        var tracker = EdgeSliderTracker(left: .none, right: .none, bottom: .seek)
        _ = tracker.update(touch(0.50, 0.03))
        _ = tracker.update(touch(0.51, 0.10))
        #expect(!tracker.holding)
        #expect(tracker.update(touch(0.80, 0.10)).isEmpty)
    }

    @Test func topEdgeOnlyWhenSet() {
        var tracker = EdgeSliderTracker(left: .none, right: .none)
        _ = tracker.update(touch(0.50, 0.97))
        #expect(!tracker.holding)
        tracker = EdgeSliderTracker(left: .none, right: .none, top: .volume)
        _ = tracker.update(touch(0.50, 0.97))
        #expect(tracker.update(touch(0.40, 0.97)) == [EdgeStep(action: .volume, up: false)])
    }

    @Test func inACornerTheFirstNotchPicksTheEdge() {
        var tracker = EdgeSliderTracker(left: .none, right: .volume, bottom: .seek)
        _ = tracker.update(touch(0.97, 0.03))
        // Sideways reaches a notch first: the bottom edge, and up and down no longer count.
        #expect(tracker.update(touch(0.87, 0.05)) == [EdgeStep(action: .seek, up: false)])
        #expect(tracker.update(touch(0.87, 0.40)).isEmpty)
        _ = tracker.update([])
        _ = tracker.update(touch(0.97, 0.03))
        #expect(tracker.update(touch(0.96, 0.17)) == [EdgeStep(action: .volume, up: true)])
    }

    @Test func pressingTheTrackpadIsNotASlide() {
        var tracker = EdgeSliderTracker(left: .none, right: .none, bottom: .seek)
        _ = tracker.update(first: EdgeTouch(id: 1, x: 0.50, y: 0.03), count: 1)
        #expect(tracker.update(first: EdgeTouch(id: 1, x: 0.50, y: 0.03), count: 1, pressed: true).isEmpty)
        #expect(!tracker.holding)
        // A click-drag: ignored until the finger is lifted, even once the press ends.
        #expect(tracker.update(first: EdgeTouch(id: 1, x: 0.70, y: 0.03), count: 1).isEmpty)
    }
}

@Suite struct CornerTapTests {
    private func finger(_ x: Float, _ y: Float) -> EdgeTouch { EdgeTouch(id: 1, x: x, y: y) }

    /// Taps at `starts` (seconds) lasting `length` each, at (x, y); returns the corners each tap's lift gave.
    private func taps(_ tracker: inout CornerTapTracker, at starts: [Double], x: Float = 0.95, y: Float = 0.95,
                      length: Double = 0.1) -> [TrackpadCorner?] {
        starts.map { start in
            _ = tracker.update(first: finger(x, y), count: 1, time: start)
            _ = tracker.update(first: finger(x, y), count: 1, time: start + length / 2)
            return tracker.update(first: nil, count: 0, time: start + length)
        }
    }

    @Test func doubleTapInACorner() {
        var tracker = CornerTapTracker(corners: [.topRight])
        #expect(taps(&tracker, at: [0, 0.3]) == [nil, .topRight])
        // A third tap starts over.
        #expect(taps(&tracker, at: [0.6]) == [nil])
    }

    @Test func holdsWhileTheFingerIsDown() {
        var tracker = CornerTapTracker(corners: [.topRight])
        _ = tracker.update(first: finger(0.95, 0.95), count: 1, time: 0)
        #expect(tracker.holding)
        _ = tracker.update(first: nil, count: 0, time: 0.1)
        #expect(!tracker.holding)
    }

    @Test func onlyCornersWithAnAction() {
        var tracker = CornerTapTracker(corners: [.topRight])
        #expect(taps(&tracker, at: [0, 0.3], x: 0.05) == [nil, nil])
        #expect(taps(&tracker, at: [1, 1.3], x: 0.5, y: 0.5) == [nil, nil])
        #expect(!tracker.holding)
    }

    @Test func slowOrLongTapsAreNotADoubleTap() {
        var tracker = CornerTapTracker(corners: [.bottomLeft])
        #expect(taps(&tracker, at: [0, 0.8], x: 0.05, y: 0.05) == [nil, nil])
        #expect(taps(&tracker, at: [2, 2.4], x: 0.05, y: 0.05, length: 0.5) == [nil, nil])
    }

    @Test func movingOrASecondFingerIsNotATap() {
        var tracker = CornerTapTracker(corners: [.topRight])
        _ = taps(&tracker, at: [0])
        _ = tracker.update(first: finger(0.95, 0.95), count: 1, time: 0.3)
        _ = tracker.update(first: finger(0.88, 0.95), count: 1, time: 0.35)
        #expect(!tracker.holding)
        #expect(tracker.update(first: nil, count: 0, time: 0.4) == nil)
        _ = taps(&tracker, at: [1])
        _ = tracker.update(first: finger(0.95, 0.95), count: 2, time: 1.3)
        #expect(tracker.update(first: nil, count: 0, time: 1.35) == nil)
    }

    @Test func cornerZones() {
        #expect(CornerTapTracker.corner(x: 0.05, y: 0.95) == .topLeft)
        #expect(CornerTapTracker.corner(x: 0.95, y: 0.95) == .topRight)
        #expect(CornerTapTracker.corner(x: 0.05, y: 0.05) == .bottomLeft)
        #expect(CornerTapTracker.corner(x: 0.95, y: 0.05) == .bottomRight)
        #expect(CornerTapTracker.corner(x: 0.50, y: 0.95) == nil)
        #expect(CornerTapTracker.corner(x: 0.05, y: 0.50) == nil)
    }

    @Test func config() throws {
        let raw = #"{ "trackpad": { "bottomEdge": "Seek", "corners": { "topRight": "media mute", "topLeft": "none", "bottomLeft": "" } } }"#
        let config = try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data(raw.utf8)))
        #expect(config.trackpad.bottomEdge == .seek)
        #expect(config.trackpad.topEdge == .none)
        #expect(config.trackpad.corners == [.topRight: .media(.mute)])
        // Corners work with the sliders off; clicks are watched to drop a tap's.
        #expect(config.trackpad.isActive && !config.trackpad.slidersActive)
        let down = CGEventMask(1) << CGEventType.leftMouseDown.rawValue
        #expect(config.tap.holdsPointer && config.tap.holdsCornerClicks && config.tap.eventMask & down != 0)
        for bad in [#"{ "trackpad": { "corners": { "middle": "media mute" } } }"#,
                    #"{ "trackpad": { "corners": { "topRight": "explode" } } }"#] {
            #expect(throws: ConfigError.self) { try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data(bad.utf8))) }
        }
    }

    @Test func settingsReadTheCorners() {
        let section: [String: Any] = ["corners": ["topRight": "media mute", "topLeft": "none", "nowhere": "media next", "bottomLeft": 3]]
        #expect(TrackpadModel.corners(in: section) == [.topRight: "media mute"])
    }
}

extension EdgeSliderTracker {
    /// A frame given as all its fingers, as the tests write it.
    mutating func update(_ touches: [EdgeTouch]) -> [EdgeStep] {
        update(first: touches.first, count: touches.count)
    }
}
