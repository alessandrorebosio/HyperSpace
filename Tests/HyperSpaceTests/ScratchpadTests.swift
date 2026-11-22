import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

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

    /// The size in the config, as fractions of the display, kept between 0.2 and 1.
    /// (The scratchpad verbs are parsed in `ActionParseTests`.)
    @Test func sizeIsClamped() throws {
        #expect(try config(#"{"tiling":{"scratchpad":{"width":0.5,"height":2}}}"#).tiling.scratchpadSize == CGSize(width: 0.5, height: 1))
        #expect(try config(#"{"tiling":{"scratchpad":{"width":0.1}}}"#).tiling.scratchpadSize
                == CGSize(width: 0.2, height: TilingConfig.defaultScratchpadSize.height))
        #expect(try config("{}").tiling.scratchpadSize == TilingConfig.defaultScratchpadSize)
    }
}
