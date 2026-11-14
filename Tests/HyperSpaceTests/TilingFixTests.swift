import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// Columns keep the windows out of sight (minimized, hidden, another Space).
@Suite struct ColumnMembershipTests {
    @Test func windowsOutOfSightKeepTheirColumn() {
        var layout = ColumnLayout(columns: [[1, 2], [3], [4]])
        // 2 and 3 are minimized: still members, so the sync keeps them.
        layout.sync(with: [1, 2, 3, 4])
        #expect(layout.columns.map(\.windows) == [[1, 2], [3], [4]])
        // Only what is on screen is laid out, closing up the gaps.
        let shown = layout.restricted(to: [1, 4])
        #expect(shown.columns.map(\.windows) == [[1], [4]])
        let frames = shown.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(frames[4] == CGRect(x: 510, y: 0, width: 500, height: 600))
        #expect(frames[2] == nil && frames[3] == nil)
        // Back on screen: where they were.
        #expect(layout.restricted(to: [1, 2, 3, 4]).columns.map(\.windows) == [[1, 2], [3], [4]])
    }

    @Test func accordionOutOfSightIsAPlainColumnMeanwhile() {
        var layout = ColumnLayout(columns: [[1, 2, 3]], accordions: [0])
        layout.setFront(2)
        let shown = layout.restricted(to: [1])
        #expect(!shown.columns[0].accordion && shown.columns[0].front == nil)
        #expect(layout.columns[0].accordion && layout.columns[0].front == 2)
    }

    @Test func replaceTakesTheSlot() {
        var layout = ColumnLayout(columns: [[1, 2], [3]], accordions: [0])
        layout.setFront(1)
        layout.replace(1, with: 9)
        #expect(layout.columns.map(\.windows) == [[9, 2], [3]])
        #expect(layout.columns[0].front == 9)
        // A window already in the layout moves into the slot.
        layout.replace(9, with: 3)
        #expect(layout.columns.map(\.windows) == [[3, 2]])
        // Not there: nothing changes.
        layout.replace(42, with: 2)
        #expect(layout.columns.map(\.windows) == [[3, 2]])
    }

    @Test func restoredWindowGoesBackToItsPlace() {
        let saved: [[CGWindowID]] = [[1, 2], [3], [4, 5]]
        var layout = ColumnLayout(columns: [[1], [4]])
        // Next to a saved column-mate: below the one above it, above the one below it.
        layout.insert(2, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [4]])
        layout.insert(5, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [4, 5]])
        // No column-mate here: a column of its own beside its saved neighbours'.
        layout.insert(3, saved: saved)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3], [4, 5]])
        // Already placed (as a new column on the right): moved, not duplicated.
        var late = ColumnLayout(columns: [[4], [1]])
        late.insert(1, saved: saved)
        #expect(late.columns.map(\.windows) == [[1], [4]])
        // Unknown to the saved arrangement: on the right.
        late.insert(8, saved: saved)
        #expect(late.columns.map(\.windows) == [[1], [4], [8]])
    }
}

@Suite struct RestoreTests {
    typealias W = WindowManager

    @Test func orderAllRestoredAtOnce() {
        // As before: restored windows first in saved order, then the others.
        let order = W.restoredOrder([7, 3, 8, 1], savedIndex: [3: 1, 1: 0], placing: [3, 1])
        #expect(order == [1, 3, 7, 8])
    }

    @Test func orderLateWindowKeepsWhatWasArranged() {
        // 10 and 11 were restored and then swapped by hand; 12 (saved between them) comes late.
        let savedIndex: [CGWindowID: Int] = [10: 0, 11: 2, 12: 1]
        let order = W.restoredOrder([11, 10, 5, 12], savedIndex: savedIndex, placing: [12])
        // Before the first restored window saved after it; 11 stays before 10.
        #expect(order == [12, 11, 10, 5])
        // Saved after every restored one: right after them, before the rest.
        let after = W.restoredOrder([10, 5], savedIndex: [10: 0, 13: 4], placing: [13])
        #expect(after == [10, 13, 5])
    }

    @Test func newWindowOfARunningAppClaimsOnlyByTitle() {
        let state = WorkspaceState(windows: [
            .init(app: "com.apple.Terminal", title: "build", workspace: 3),
            .init(app: "com.apple.Terminal", title: "logs", workspace: 4),
        ])
        var restorer = WorkspaceRestorer(state, windowsAtStart: [100], appsAtStart: [7])
        // ⌘N in Terminal, running before the restore: a new window, not a saved one.
        #expect(restorer.claim(app: "com.apple.Terminal", title: "zsh", window: 200, pid: 7) == nil)
        // Unless its title is a saved one's.
        #expect(restorer.claim(app: "com.apple.Terminal", title: "logs", window: 201, pid: 7) == 1)
        // A window there at the start takes the next saved window of its app.
        #expect(restorer.claim(app: "com.apple.Terminal", title: "other", window: 100, pid: 7) == 0)
    }

    @Test func appOpenedSinceTheStartClaimsByApp() {
        let state = WorkspaceState(windows: [.init(app: "com.apple.Safari", title: "GitHub", workspace: 1)])
        var restorer = WorkspaceRestorer(state, windowsAtStart: [], appsAtStart: [7])
        #expect(restorer.claim(app: "com.apple.Safari", title: "Apple", window: 300, pid: 9) == 0)
    }

    @Test func titlesAloneAreNoChange() {
        var a = WorkspaceState(savedAt: .distantPast, windows: [.init(app: "a", title: "one", workspace: 1)])
        var b = a
        b.windows[0].title = "two"
        #expect(a != b)
        #expect(a.withoutTitles == b.withoutTitles)
        a.windows[0].workspace = 2
        #expect(a.withoutTitles != b.withoutTitles)
    }
}

@Suite struct RevealTests {
    @Test func onlyAppsYouJustOpenedWithARule() {
        func reveals(assigned: Int? = 2, launched: Bool = true, restored: Bool = false, scratchpad: Bool = false,
                     dialog: Bool = false, revealAfter: Date = .distantPast) -> Bool {
            WindowManager.revealsWorkspace(assigned: assigned, workspaces: 4, launched: launched, restored: restored,
                                           scratchpad: scratchpad, dialog: dialog, now: Date(), revealAfter: revealAfter)
        }
        #expect(reveals())
        #expect(!reveals(assigned: nil))
        #expect(!reveals(assigned: 7))
        #expect(!reveals(launched: false))
        #expect(!reveals(restored: true))
        #expect(!reveals(scratchpad: true))
        #expect(!reveals(dialog: true))
        // During the login grace.
        #expect(!reveals(revealAfter: .distantFuture))
    }
}

@Suite struct WorkspaceCountTests {
    @Test func windowsOfRemovedWorkspacesJoinTheFirst() {
        let fitted = WindowManager.fittedWorkspaces([1: 0, 2: 1, 3: 2, 4: 5], count: 2)
        #expect(fitted == [1: 0, 2: 1, 3: 0, 4: 0])
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

    @Test func leastSeenWhenBothCornersAreCovered() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1200)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1200)
        #expect(W.parkingPoint(size: size, on: main, others: [right, left]) == CGPoint(x: 1439, y: 899))
    }

    @Test func aParkedWindowIsOnTheDisplayOfItsSliver() {
        let screens = [ScreenInfo(id: 1, frame: main, visible: main),
                       ScreenInfo(id: 2, frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                  visible: CGRect(x: 1440, y: 0, width: 1920, height: 1080))]
        // Parked bottom-left of the right display: its center is nearer the main one.
        let parked = CGRect(x: 1440 - 1000 + 1, y: 1079, width: 1000, height: 700)
        #expect(W.isParked(parked, on: screens))
        #expect(W.displayIndex(of: parked, screens) == 1)
        #expect(W.displayIndex(of: CGRect(x: 100, y: 100, width: 400, height: 300), screens) == 0)
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
