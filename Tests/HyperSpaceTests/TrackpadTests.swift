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
        #expect(tracker.update(touch(0.96, 0.54)).isEmpty)
        #expect(tracker.update(touch(0.96, 0.57)) == [EdgeStep(action: .volume, up: true)])
        // Two notches in one frame, then two back down.
        #expect(tracker.update(touch(0.96, 0.66)) == Array(repeating: EdgeStep(action: .volume, up: true), count: 2))
        #expect(tracker.update(touch(0.96, 0.54)) == Array(repeating: EdgeStep(action: .volume, up: false), count: 2))
        #expect(tracker.update([]).isEmpty)
        #expect(!tracker.holding)
    }

    @Test func leftEdgeHasItsOwnAction() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        _ = tracker.update(touch(0.03, 0.50))
        #expect(tracker.update(touch(0.03, 0.44)) == [EdgeStep(action: .brightness, up: false)])
    }

    @Test func pointerMovesAreLeftAlone() {
        var tracker = EdgeSliderTracker(left: .brightness, right: .volume)
        // Starting in the middle.
        _ = tracker.update(touch(0.50, 0.50))
        #expect(!tracker.holding)
        #expect(tracker.update(touch(0.50, 0.70)).isEmpty)
        _ = tracker.update([])
        // Starting on the edge but moving sideways: the hold lifts, nothing follows.
        _ = tracker.update(touch(0.95, 0.50))
        _ = tracker.update(touch(0.88, 0.52))
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
        #expect(on.trackpad.isActive)
        // Pointer moves are watched only with the sliders on, to hold the pointer during a slide.
        let moved = CGEventMask(1) << CGEventType.mouseMoved.rawValue
        #expect(on.tap.holdsPointer && on.tap.eventMask & moved != 0)
        #expect(!off.tap.holdsPointer && off.tap.eventMask & moved == 0)
        let bad = #"{ "trackpad": { "leftEdge": "mute" } }"#
        #expect(throws: ConfigError.self) { try HyperSpace.Config(JSONDecoder().decode(RawConfig.self, from: Data(bad.utf8))) }
    }
}

extension EdgeSliderTracker {
    /// A frame given as all its fingers, as the tests write it.
    mutating func update(_ touches: [EdgeTouch]) -> [EdgeStep] {
        update(first: touches.first, count: touches.count)
    }
}
