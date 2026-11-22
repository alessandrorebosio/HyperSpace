import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// Displays as the window manager sees them: frames, order, pins.
@Suite struct ScreenInfoTests {
    private let screens = [makeScreen(1, name: "Built-in Retina Display"), makeScreen(2, x: 1000, name: "LG UltraFine"),
                           makeScreen(3, x: 2000)]

    @Test func centered() {
        let screen = makeScreen(0, width: 800, height: 600, menuBar: 25)
        #expect(screen.centered(CGSize(width: 1000, height: 300)) == CGRect(x: 0, y: 162.5, width: 800, height: 300))
    }

    /// Moving to another display keeps position and size as shares of the visible area.
    @Test func relocate() {
        let small = makeScreen(1)
        let large = makeScreen(2, x: 1000, y: -200, width: 2000, height: 1225, menuBar: 25)
        #expect(small.relocate(CGRect(x: 250, y: 150, width: 500, height: 300), to: large)
                == CGRect(x: 1500, y: 125, width: 1000, height: 600))
        // Too big for the destination: shrunk and kept inside it.
        #expect(large.relocate(CGRect(x: 1000, y: -175, width: 2000, height: 1200), to: small) == small.visible)
    }

    /// AppKit's bottom-left coordinates against the main display's height, and back.
    @Test func flipped() {
        let rect = CGRect(x: 10, y: 0, width: 100, height: 50)
        #expect(ScreenInfo.flipped(rect, height: 900) == CGRect(x: 10, y: 850, width: 100, height: 50))
        #expect(ScreenInfo.flipped(ScreenInfo.flipped(rect, height: 900), height: 900) == rect)
        #expect(ScreenInfo.flipped(CGPoint(x: 10, y: 20), height: 900) == CGPoint(x: 10, y: 880))
    }

    @Test func nextWrapsAround() {
        #expect(screens.next(after: 1)?.id == 2)
        #expect(screens.next(after: 3)?.id == 1)
        #expect(screens.next(after: 9) == nil)
        #expect([makeScreen(1)].next(after: 1)?.id == 1)
        #expect(screens.first(id: 2)?.name == "LG UltraFine")
    }

    /// The display a frame is on: the one holding its center, else the nearest.
    @Test func screenForAFrame() {
        #expect(screens.index(for: CGRect(x: 1100, y: 100, width: 200, height: 200)) == 1)
        #expect(screens.screen(for: CGRect(x: 1100, y: 100, width: 200, height: 200))?.id == 2)
        // Its center on no display: the nearest one.
        #expect(screens.index(for: CGRect(x: -500, y: 100, width: 100, height: 100)) == 0)
        #expect(screens.index(for: CGRect(x: 3500, y: 100, width: 100, height: 100)) == 2)
        #expect([ScreenInfo]().screen(for: .zero) == nil)
        #expect([ScreenInfo]().index(for: .zero) == 0)
    }

    /// "main" is the first display, a number the n-th; then a name, exact or in part, in any case.
    @Test func pinnedByNameOrPosition() {
        let named = [makeScreen(1, name: "Built-in Retina Display"), makeScreen(2, x: 1000, name: "LG UltraFine"),
                     makeScreen(3, x: 2000, name: "DELL U2720Q")]
        #expect(ScreenInfo.pinned("main", among: named)?.id == 1)
        #expect(ScreenInfo.pinned(" Main ", among: named)?.id == 1)
        #expect(ScreenInfo.pinned("dell u2720q", among: named)?.id == 3)
        #expect(ScreenInfo.pinned("ultrafine", among: named)?.id == 2)
        #expect(ScreenInfo.pinned("Samsung", among: named) == nil)
        #expect(ScreenInfo.pinned("", among: named) == nil)
        #expect(ScreenInfo.pinned("main", among: []) == nil)
    }

    @Test func aPositionFollowsWhicheverMonitorIsThere() {
        let two = Array(screens.prefix(2))
        #expect(ScreenInfo.pinned("2", among: two)?.id == 2)
        #expect(ScreenInfo.pinned("3", among: two) == nil)
        #expect(ScreenInfo.pinned("0", among: two) == nil)
        #expect(ScreenInfo.pinned("2", among: [makeScreen(1), makeScreen(7, x: -1000)])?.id == 7)
    }

    /// Settings pins by name, or by something else that tells two identical monitors apart.
    @Test func pinValueTellsTwinsApart() {
        let lg = makeScreen(2, x: 1000, name: "LG UltraFine")
        let twin = makeScreen(4, x: 2000, name: "lg ultrafine")
        let builtIn = makeScreen(1, name: "Built-in Retina Display")
        #expect(lg.pinValue(among: [builtIn, lg]) == "LG UltraFine")
        let values = [lg, twin].map { $0.pinValue(among: [builtIn, lg, twin]) }
        #expect(values[0] != values[1])
        #expect(!values.contains { $0.caseInsensitiveCompare("LG UltraFine") == .orderedSame })
        #expect(builtIn.pinValue(among: [builtIn, lg, twin]) == "Built-in Retina Display")
        // A display with no name has only the other value.
        #expect(makeScreen(5).pinValue(among: []) != "")
    }
}

@Suite struct ScreenNeighborTests {
    /// An empty display has no window to find: the display itself is the target.
    @Test func nearestDisplayThatWay() {
        let screens = [makeScreen(1), makeScreen(2, x: 1000), makeScreen(3, x: 2000), makeScreen(4, y: -600)]
        #expect(screens.neighbor(of: 1, .right)?.id == 2)
        #expect(screens.neighbor(of: 2, .left)?.id == 1)
        #expect(screens.neighbor(of: 2, .right)?.id == 3)
        #expect(screens.neighbor(of: 1, .up)?.id == 4)
        #expect(screens.neighbor(of: 4, .down)?.id == 1)
        #expect(screens.neighbor(of: 1, .left) == nil)
        #expect(screens.neighbor(of: 3, .right) == nil)
        #expect(screens.neighbor(of: 9, .right) == nil)
    }
}

@Suite struct ParkingTests {
    private let screens = [makeScreen(1, width: 1000, height: 800, menuBar: 25)]

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

@Suite struct ParkingCornerTests {
    typealias W = WindowManager
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: 800, height: 600)

    @Test func bottomRightWhenNothingIsThere() {
        #expect(W.parkingPoint(size: size, on: main, others: []) == CGPoint(x: 1439, y: 899))
        // A display on the left does not see the bottom-right corner.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(W.parkingPoint(size: size, on: main, others: [left]) == CGPoint(x: 1439, y: 899))
    }

    @Test func bottomLeftWhenADisplayIsBeyondTheRightCorner() {
        // A taller display on the right: a window parked bottom-right would show in its strip.
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1200)
        #expect(W.parkingPoint(size: size, on: main, others: [right]) == CGPoint(x: -799, y: 899))
    }

    @Test func aFreeCornerOfAnotherDisplayWhenBothCornersAreCovered() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1200)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        // Bottom-right of the right display: no display is beyond it.
        #expect(W.parkingPoint(size: size, on: main, others: [right, left]) == CGPoint(x: 3359, y: 1199))
    }

    @Test func aParkedWindowIsOnTheDisplayOfItsSliver() {
        let screens = [makeScreen(1, width: 1440, height: 900), makeScreen(2, x: 1440, width: 1920, height: 1080)]
        // Parked bottom-left of the right display: its center is nearer the main one.
        let parked = CGRect(x: 1440 - 1000 + 1, y: 1079, width: 1000, height: 700)
        #expect(W.isParked(parked, on: screens))
        #expect(W.displayIndex(of: parked, screens) == 1)
        #expect(W.displayIndex(of: CGRect(x: 100, y: 100, width: 400, height: 300), screens) == 0)
    }
}

@Suite struct OutOfSightTests {
    typealias W = WindowManager
    let main = makeScreen(1, width: 1440, height: 900, menuBar: 25)

    @Test func aFrameNoDisplayShowsIsCentered() {
        // On a display to the right that is gone (or left out while it sleeps).
        let away = CGRect(x: 2000, y: 100, width: 600, height: 400)
        #expect(W.isOutOfSight(away, on: [main]))
        #expect(W.place(away, on: main, [main]) == main.centered(away.size))
        // In view, or parked with a point in view: kept.
        let here = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(!W.isOutOfSight(here, on: [main]))
        #expect(W.place(here, on: main, [main]) == here)
        #expect(!W.isOutOfSight(CGRect(x: 1439, y: 899, width: 600, height: 400), on: [main]))
    }

    @Test func parkedOnAnotherDisplaysCornerWhenBothOwnCornersShow() {
        // A wider display below: both bottom corners of the one above lie over it.
        let top = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let below = CGRect(x: -500, y: 900, width: 2560, height: 1440)
        let size = CGSize(width: 800, height: 600)
        #expect(W.parkingPoint(size: size, on: top, others: [below]) == CGPoint(x: 2059, y: 2339))
    }
}

@Suite struct DisplayMonitorRuleTests {
    let now = Date()

    @Test func darkForTheGraceIsLeftOut() {
        let displays: [CGDirectDisplayID] = [1, 2]
        let soon = DisplayMonitor.absentDisplays(previous: [], displays: displays, darkSince: [2: now - 10], now: now)
        #expect(soon.isEmpty)
        let later = DisplayMonitor.absentDisplays(previous: [], displays: displays,
                                                  darkSince: [2: now - DisplayMonitor.grace], now: now)
        #expect(later == [2])
    }

    @Test func awakeAgainIsBackAtOnce() {
        #expect(DisplayMonitor.absentDisplays(previous: [2], displays: [1, 2], darkSince: [:], now: now).isEmpty)
        // Unplugged meanwhile: forgotten.
        #expect(DisplayMonitor.absentDisplays(previous: [3], displays: [1, 2], darkSince: [:], now: now).isEmpty)
    }

    @Test func everyDisplayDarkChangesNothing() {
        let long = now - DisplayMonitor.grace * 2
        // The Mac sleeps: no new display is left out, and one left out stays so.
        #expect(DisplayMonitor.absentDisplays(previous: [], displays: [1, 2], darkSince: [1: long, 2: long], now: now).isEmpty)
        #expect(DisplayMonitor.absentDisplays(previous: [2], displays: [1, 2], darkSince: [1: long, 2: long], now: now) == [2])
    }
}
