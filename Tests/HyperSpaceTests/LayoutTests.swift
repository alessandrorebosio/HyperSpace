import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct ColumnLayoutTests {
    @Test func stackAndUnstack() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        layout.move(2, .down)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        layout.sync(with: [1, 2, 3])
        layout.move(3, .up)
        #expect(layout.columns.map(\.windows) == [[3, 1, 2]])
        layout.move(3, .down)
        #expect(layout.columns.map(\.windows) == [[1, 3, 2]])
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
        layout.move(2, .left)
        #expect(layout.columns.map(\.windows) == [[2], [1, 3]])
        layout.sync(with: [1, 2])
        #expect(layout.columns.map(\.windows) == [[2], [1]])
    }

    @Test func frames() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        let side = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10, peek: 30) { _ in 1 }
        #expect(side[1] == CGRect(x: 0, y: 0, width: 500, height: 610))
        #expect(side[2] == CGRect(x: 510, y: 0, width: 500, height: 610))
        layout.move(2, .down)
        let stacked = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10, peek: 30) { _ in 1 }
        #expect(stacked[2] == CGRect(x: 0, y: 310, width: 1010, height: 300))
    }
}

@Suite struct ColumnAccordionTests {
    /// Two windows side by side → one accordion → moving one out puts them side by side again.
    @Test func toggleAndMoveOut() {
        var layout = ColumnLayout(columns: [[1], [2]])
        let on = layout.toggleAccordion(around: 2)
        #expect(on)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        #expect(layout.columns[0].accordion && layout.columns[0].front == 2)
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 970, height: 600))
        #expect(frames[2] == CGRect(x: 30, y: 0, width: 970, height: 600))
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(!layout.columns[0].accordion)
    }

    @Test func toggleOffAndNewWindows() {
        var layout = ColumnLayout(columns: [[1], [2, 3]])
        layout.toggleAccordion(around: 1)
        // A new window opened while the accordion has the focus joins it.
        layout.sync(with: [1, 2, 3, 4], focused: 1)
        #expect(layout.columns.map(\.windows) == [[1, 4, 2, 3]])
        #expect(layout.accordionNeighbor(of: 4, 1) == 2)
        let still = layout.toggleAccordion(around: 4)
        #expect(!still)
        #expect(layout.columns.map(\.windows) == [[1], [4], [2], [3]])
    }
}

@Suite struct LayoutTests {
    @Test func weightedTall() {
        let frames = Layout.frames(.tall, weights: [1, 1, 2], in: CGRect(x: 0, y: 0, width: 1000, height: 610), gap: 10, ratio: 0.5)
        #expect(frames.map(\.height) == [610, 200, 400])
    }

    @Test func resizeWeight() {
        // Two equal columns of 500: +50 → 550 wide.
        let weight = WindowManager.weight(at: 0, of: [1, 1], growingBy: 50, length: 1010, gap: 10)
        #expect(abs(1000 * weight / (weight + 1) - 550) < 0.001)
    }

    /// Workspace n lives on display n; the others on the main display (index 0).
    @Test func workspaceHomes() {
        #expect((0..<6).map { WindowManager.homeIndex(of: $0, displays: 2) } == [0, 1, 0, 0, 0, 0])
        #expect((0..<4).map { WindowManager.homeIndex(of: $0, displays: 3) } == [0, 1, 2, 0])
        #expect(WindowManager.homeIndex(of: 1, displays: 1) == 0)
    }

    @Test func centered() {
        let screen = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                visible: CGRect(x: 0, y: 25, width: 800, height: 575))
        #expect(screen.centered(CGSize(width: 1000, height: 300)) == CGRect(x: 0, y: 162.5, width: 800, height: 300))
    }

    /// Same-size windows; the ones before the focused one on the left edge, after it on the right.
    @Test func accordion() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let middle = Layout.frames(.accordion, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: 1, peek: 30)
        #expect(middle == [CGRect(x: 0, y: 0, width: 940, height: 600),
                           CGRect(x: 30, y: 0, width: 940, height: 600),
                           CGRect(x: 60, y: 0, width: 940, height: 600)])
        let first = Layout.frames(.accordion, weights: [1, 1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30)
        #expect(first == [CGRect(x: 0, y: 0, width: 970, height: 600), CGRect(x: 30, y: 0, width: 970, height: 600)])
        #expect(Layout.frames(.accordion, weights: [1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30) == [area])
    }

    /// Moving to another display keeps position and size as shares of the visible area.
    @Test func relocate() {
        let small = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                               visible: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let large = ScreenInfo(id: 2, frame: CGRect(x: 1000, y: -200, width: 2000, height: 1225),
                               visible: CGRect(x: 1000, y: -175, width: 2000, height: 1200))
        #expect(small.relocate(CGRect(x: 250, y: 150, width: 500, height: 300), to: large)
                == CGRect(x: 1500, y: 125, width: 1000, height: 600))
        // Too big for the destination: shrunk and kept inside it.
        #expect(large.relocate(CGRect(x: 1000, y: -175, width: 2000, height: 1200), to: small) == small.visible)
    }
}

@Suite struct ScreenNeighborTests {
    func screen(_ id: CGDirectDisplayID, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1000, _ h: CGFloat = 600) -> ScreenInfo {
        let frame = CGRect(x: x, y: y, width: w, height: h)
        return ScreenInfo(id: id, frame: frame, visible: frame)
    }

    /// An empty display has no window to find: the display itself is the target.
    @Test func nearestDisplayThatWay() {
        let screens = [screen(1, 0, 0), screen(2, 1000, 0), screen(3, 2000, 0), screen(4, 0, -600)]
        #expect(screens.neighbor(of: 1, .right)?.id == 2)
        #expect(screens.neighbor(of: 2, .left)?.id == 1)
        #expect(screens.neighbor(of: 2, .right)?.id == 3)
        #expect(screens.neighbor(of: 1, .up)?.id == 4)
        #expect(screens.neighbor(of: 4, .down)?.id == 1)
        #expect(screens.neighbor(of: 1, .left) == nil)
        #expect(screens.neighbor(of: 3, .right) == nil)
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

@Suite struct ParkingTests {
    private let screens = [ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), visible: CGRect(x: 0, y: 25, width: 1000, height: 775))]

    @Test func parkedAtCorner() {
        #expect(WindowManager.isParked(CGRect(x: 999, y: 799, width: 400, height: 300), on: screens))
    }

    @Test func insideScreenIsNotParked() {
        #expect(!WindowManager.isParked(CGRect(x: 100, y: 100, width: 400, height: 300), on: screens))
    }

    @Test func offEveryScreenIsParked() {
        #expect(WindowManager.isParked(CGRect(x: 3000, y: 100, width: 400, height: 300), on: screens))
    }

    @Test func halfOnScreenIsNotParked() {
        #expect(!WindowManager.isParked(CGRect(x: 800, y: 100, width: 400, height: 300), on: screens))
    }
}

@Suite struct ScratchpadTests {
    @Test func frameIsCentered() {
        let visible = CGRect(x: 0, y: 33, width: 1470, height: 923)
        let frame = WindowManager.scratchpadFrame(in: visible, size: CGSize(width: 0.6, height: 0.7))
        #expect(frame.width == 882 && frame.height == 646)
        #expect(abs(frame.midX - visible.midX) <= 1 && abs(frame.midY - visible.midY) <= 1)
    }

    @Test func windowMissingTheSizeStaysCentered() {
        let frame = CGRect(x: 294, y: 172, width: 882, height: 646)
        // A terminal that only takes whole character cells.
        let fitted = frame.centered(CGSize(width: 875, height: 640), rounded: true)
        #expect(fitted == CGRect(x: 298, y: 175, width: 875, height: 640))
        #expect(frame.centered(frame.size, rounded: true) == frame)
    }

    @Test func nearFittedSizeIsShared() {
        let target = CGRect(x: 74, y: 126, width: 1323, height: 738)
        let frame = WindowManager.scratchpadFrame(target: target, fitted: (target, CGSize(width: 1316, height: 731)))
        #expect(frame.size == CGSize(width: 1316, height: 731))
        #expect(abs(frame.midX - target.midX) <= 1 && abs(frame.midY - target.midY) <= 1)
    }

    @Test func farFittedSizeIsIgnored() {
        // A window left at the full visible area (a move that failed) is not the size to share.
        let target = CGRect(x: 74, y: 126, width: 1323, height: 738)
        #expect(WindowManager.scratchpadFrame(target: target, fitted: (target, CGSize(width: 1469, height: 922))) == target)
        #expect(!WindowManager.isNearFit(CGSize(width: 1469, height: 922), target.size))
    }

    @Test func fittedSizeOfAnotherTargetIsIgnored() {
        let target = CGRect(x: 74, y: 126, width: 1323, height: 738)
        let other = CGRect(x: 0, y: 0, width: 1000, height: 700)
        #expect(WindowManager.scratchpadFrame(target: target, fitted: (other, CGSize(width: 1316, height: 731))) == target)
        #expect(WindowManager.scratchpadFrame(target: target, fitted: nil) == target)
    }

    @Test func actionsAndSize() throws {
        let config = try HyperSpaceTests.config(#"""
        {"keyboard":{"bindings":[{"keys":"meh+x","action":"scratchpad com.anthropic.claudefordesktop"},
                                 {"keys":"hyper+x","action":"move-to-scratchpad"},{"keys":"meh+z","action":"scratchpad"},
                                 {"keys":"hyper+c","action":"move-to-scratchpad com.anthropic.claudefordesktop"}]},
         "tiling":{"scratchpad":{"width":0.5,"height":2}}}
        """#)
        #expect(try action(config, "meh+x") == .scratchpad("com.anthropic.claudefordesktop"))
        #expect(try action(config, "hyper+x") == .moveToScratchpad(nil))
        #expect(try action(config, "meh+z") == .scratchpad(nil))
        #expect(try action(config, "hyper+c") == .moveToScratchpad("com.anthropic.claudefordesktop"))
        #expect(config.tiling.scratchpadSize == CGSize(width: 0.5, height: 1))
    }
}
