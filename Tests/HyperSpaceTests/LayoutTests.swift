import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// `Layout.frames` for every layout kind.
@Suite struct LayoutTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func weightedTall() {
        let frames = Layout.frames(.tall, weights: [1, 1, 2], in: CGRect(x: 0, y: 0, width: 1000, height: 610), gap: 10, ratio: 0.5)
        #expect(frames.map(\.height) == [610, 200, 400])
    }

    /// The master takes `ratio` of what the gap leaves, rounded; the stack the rest after the gap.
    @Test func tallMasterWidthFollowsTheRatioAndTheGap() {
        let frames = Layout.frames(.tall, weights: [1, 1], in: area, gap: 10, ratio: 0.55)
        #expect(frames == [CGRect(x: 0, y: 0, width: 545, height: 600), CGRect(x: 555, y: 0, width: 445, height: 600)])
    }

    @Test func wideMasterHeightFollowsTheRatioAndTheGap() {
        let frames = Layout.frames(.wide, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5)
        #expect(frames == [CGRect(x: 0, y: 0, width: 1000, height: 295),
                           CGRect(x: 0, y: 305, width: 495, height: 295),
                           CGRect(x: 505, y: 305, width: 495, height: 295)])
    }

    @Test func oneWindowOrNone() {
        #expect(Layout.frames(.tall, weights: [1], in: area, gap: 10, ratio: 0.55) == [area])
        #expect(Layout.frames(.columns, weights: [], in: area, gap: 10, ratio: 0.55).isEmpty)
    }

    @Test func resizeWeight() {
        // Two equal columns of 500: +50 → 550 wide.
        let weight = WindowManager.weight(at: 0, of: [1, 1], growingBy: 50, length: 1010, gap: 10)
        #expect(abs(1000 * weight / (weight + 1) - 550) < 0.001)
    }

    /// Resizing by a shortcut leaves every other tile at least `minimumTileLength` (80 points), and itself too.
    @Test func resizeWeightKeepsTheMinimumTile() {
        #expect(WindowManager.minimumTileLength == 80)
        let grown = WindowManager.weight(at: 0, of: [1, 1], growingBy: 10_000, length: 1010, gap: 10)
        #expect(abs(1000 * 1 / (grown + 1) - 80) < 0.001)
        let shrunk = WindowManager.weight(at: 0, of: [1, 1], growingBy: -10_000, length: 1010, gap: 10)
        #expect(abs(1000 * shrunk / (shrunk + 1) - 80) < 0.001)
        // Three tiles: the two others keep 80 each.
        let three = WindowManager.weight(at: 1, of: [1, 1, 1], growingBy: 10_000, length: 1020, gap: 10)
        #expect(abs(1000 * three / (three + 2) - 840) < 0.001)
    }

    /// Same-size windows; the ones before the focused one on the left edge, after it on the right.
    @Test func accordion() {
        let middle = Layout.frames(.accordion, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: 1, peek: 30)
        #expect(middle == [CGRect(x: 0, y: 0, width: 940, height: 600),
                           CGRect(x: 30, y: 0, width: 940, height: 600),
                           CGRect(x: 60, y: 0, width: 940, height: 600)])
        let first = Layout.frames(.accordion, weights: [1, 1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30)
        #expect(first == [CGRect(x: 0, y: 0, width: 970, height: 600), CGRect(x: 30, y: 0, width: 970, height: 600)])
        #expect(Layout.frames(.accordion, weights: [1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30) == [area])
    }

    /// A focused index out of range is the first or the last window.
    @Test func accordionFocusedIndexIsClamped() {
        func frames(_ focused: Int) -> [CGRect] {
            Layout.frames(.accordion, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: focused, peek: 30)
        }
        #expect(frames(0).map(\.minX) == [0, 30, 30])
        #expect(frames(2).map(\.minX) == [0, 0, 30])
        #expect(frames(-3) == frames(0))
        #expect(frames(5) == frames(2))
    }
}

/// Layout math beyond the layouts themselves.
@Suite struct LayoutMathTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func zeroWeightsSplitEvenly() {
        let frames = Layout.split(area, weights: [0, 0], horizontally: true, gap: 0)
        #expect(frames.map(\.width) == [500, 500])
    }

    /// Each tile is rounded down; the last takes what is left, so the edge stays flush.
    @Test func splitRoundsDownAndTheLastTileAbsorbsTheRest() {
        let frames = Layout.split(area, weights: [1, 1, 1], horizontally: true, gap: 0)
        #expect(frames.map(\.width) == [333, 333, 334])
        #expect(frames.map(\.minX) == [0, 333, 666])
        let rows = Layout.split(area, weights: [1, 2], horizontally: false, gap: 10)
        #expect(rows.map(\.height) == [196, 394])
        #expect(rows.last?.maxY == 600)
    }

    @Test func wideStacksUnderTheMaster() {
        let frames = Layout.frames(.wide, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: 0)
        #expect(frames[0].width == 1000 && frames[0].minY == 0)
        #expect(frames[1].minY == frames[2].minY && frames[1].minY > frames[0].maxY)
        #expect(frames[2].maxX == 1000)
    }

    @Test func monocleFillsTheArea() {
        #expect(Layout.frames(.monocle, weights: [1, 1], in: area, gap: 10, ratio: 0.5) == [area, area])
    }

    @Test func neighborPrefersOverlap() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates: [(String, CGRect)] = [
            ("far-overlapping", CGRect(x: 400, y: 0, width: 100, height: 100)),
            ("near-below", CGRect(x: 150, y: 300, width: 100, height: 100)),
        ]
        #expect(Layout.neighbor(of: origin, .right, among: candidates) == "far-overlapping")
        #expect(Layout.neighbor(of: origin, .left, among: candidates) == nil)
        #expect(Layout.neighbor(of: origin, .down, among: candidates) == "near-below")
    }
}

@Suite struct FrameStepTests {
    typealias W = WindowManager
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func onlyWhatChanges() {
        #expect(W.frameSteps(from: frame, to: frame, sameDisplay: true) == [])
        #expect(W.frameSteps(from: frame, to: frame.offsetBy(dx: 50, dy: 0), sameDisplay: true) == [.position])
        #expect(W.frameSteps(from: frame, to: CGRect(x: 100, y: 100, width: 700, height: 600), sameDisplay: true) == [.size])
    }

    @Test func shrinkBeforeMovingGrowAfter() {
        #expect(W.frameSteps(from: frame, to: CGRect(x: 0, y: 0, width: 400, height: 300), sameDisplay: true) == [.size, .position])
        #expect(W.frameSteps(from: frame, to: CGRect(x: 0, y: 0, width: 1200, height: 600), sameDisplay: true) == [.position, .size])
    }

    @Test func acrossDisplaysOrUnknown() {
        #expect(W.frameSteps(from: frame, to: frame.offsetBy(dx: 2000, dy: 0), sameDisplay: false) == [.size, .position, .size])
        #expect(W.frameSteps(from: nil, to: frame, sameDisplay: true) == [.size, .position, .size])
    }
}

@Suite struct RetileRuleTests {
    typealias W = WindowManager
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func aWindowSentAcrossDisplaysIsLookedAtAgainOncePerTile() {
        let tile = CGRect(x: 1500, y: 0, width: 400, height: 900)
        #expect(W.looksAgain(at: tile, after: nil))
        #expect(!W.looksAgain(at: tile, after: tile))
        #expect(!W.looksAgain(at: tile, after: tile.offsetBy(dx: 0.5, dy: 0)))
        #expect(W.looksAgain(at: tile, after: tile.offsetBy(dx: 200, dy: 0)))
    }

    @Test func fullScreenIsNotToldWhereATileIsAsLargeAsTheDisplay() {
        let withMenuBar = (frame: main, area: main.insetBy(dx: 8, dy: 20))
        #expect(W.isFullScreen(main, displays: [withMenuBar]))
        #expect(!W.isFullScreen(withMenuBar.area, displays: [withMenuBar]))
        // No menu bar, no Dock, no padding: a lone tile covers the display too.
        #expect(!W.isFullScreen(main, displays: [(frame: main, area: main)]))
    }

    @Test func gapsThatLeaveNoRoomAreLeftOut() {
        #expect(Layout.fittingGap(10, count: 3, length: 300) == 10)
        #expect(Layout.fittingGap(64, count: 20, length: 1000) == 0)
        let rows = Layout.split(CGRect(x: 0, y: 0, width: 400, height: 1000), weights: Array(repeating: 1, count: 20),
                                horizontally: false, gap: 64)
        #expect(rows.allSatisfy { $0.height > 0 })
        #expect(rows.last?.maxY == 1000)
        let narrow = Layout.frames(.tall, weights: [1, 1], in: CGRect(x: 0, y: 0, width: 40, height: 400), gap: 64, ratio: 0.5)
        #expect(narrow.allSatisfy { $0.width > 0 })
    }
}

/// A display's layout state.
@Suite struct ScreenStateTests {
    @Test func ratioStaysInRange() {
        var state = ScreenState(layout: .tall, ratio: 0.55)
        state.adjustRatio(by: 0.05)
        #expect(abs(state.ratio - 0.6) < 0.0001)
        state.adjustRatio(by: 1)
        #expect(state.ratio == TilingConfig.ratioRange.upperBound)
        state.adjustRatio(by: -2)
        #expect(state.ratio == TilingConfig.ratioRange.lowerBound)
    }
}
