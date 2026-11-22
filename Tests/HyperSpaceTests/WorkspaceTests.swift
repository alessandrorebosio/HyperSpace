import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct LaunchTrackerTests {
    @Test func windowsJoinTheLaunchWorkspace() {
        var tracker = LaunchTracker()
        let start = Date()
        tracker.launched(42, in: 3, at: start)
        #expect(tracker.workspace(for: 7, at: start) == nil)
        // Still loading after 20 s: the first window goes where the app was opened.
        #expect(tracker.workspace(for: 42, at: start + 20) == 3)
        // A second window right after follows it; a later one opens where you are.
        #expect(tracker.workspace(for: 42, at: start + 21) == 3)
        #expect(tracker.workspace(for: 42, at: start + 30) == nil)
    }

    @Test func launchTimesOut() {
        var tracker = LaunchTracker()
        let start = Date()
        tracker.launched(42, in: 1, at: start)
        #expect(tracker.workspace(for: 42, at: start + LaunchTracker.launchTimeout + 1) == nil)
        tracker.launched(43, in: 1, at: start)
        tracker.forget(43)
        #expect(tracker.workspace(for: 43, at: start) == nil)
    }
}

/// Which display each workspace lives on and shows, and where new windows go.
@Suite struct WorkspaceLogicTests {
    typealias W = WindowManager
    let main: CGDirectDisplayID = 1
    let top: CGDirectDisplayID = 2

    /// Workspace n lives on display n; the others on the main display (index 0).
    @Test func workspaceHomes() {
        #expect((0..<6).map { W.homeIndex(of: $0, displays: 2) } == [0, 1, 0, 0, 0, 0])
        #expect((0..<4).map { W.homeIndex(of: $0, displays: 3) } == [0, 1, 2, 0])
        #expect(W.homeIndex(of: 1, displays: 1) == 0)
    }

    @Test func homes() {
        #expect(W.homeDisplay(of: 0, movedTo: nil, displays: [main, top]) == main)
        #expect(W.homeDisplay(of: 1, movedTo: nil, displays: [main, top]) == top)
        #expect(W.homeDisplay(of: 5, movedTo: nil, displays: [main, top]) == main)
        #expect(W.homeDisplay(of: 0, movedTo: top, displays: [main, top]) == top)
        // Moved to a display that was unplugged: back on its own.
        #expect(W.homeDisplay(of: 1, movedTo: 9, displays: [main]) == main)
        #expect(W.homeDisplay(of: 0, movedTo: nil, displays: []) == nil)
    }

    /// A pin wins over the default home, and is ignored while its display is unplugged.
    @Test func pinnedDisplay() {
        let screens = [makeScreen(1, name: "Built-in Retina Display"), makeScreen(2, x: 1000, name: "LG UltraFine"),
                       makeScreen(3, x: 2000, name: "DELL U2720Q")]
        #expect(W.homeDisplay(of: 0, movedTo: ScreenInfo.pinned("3", among: screens)?.id, displays: [1, 2, 3]) == 3)
        #expect(W.homeDisplay(of: 1, movedTo: ScreenInfo.pinned("DELL", among: Array(screens.prefix(2)))?.id, displays: [1, 2]) == 2)
    }

    private func sync(_ displayed: [CGDirectDisplayID: Int], _ displays: [CGDirectDisplayID],
                      moved: [Int: CGDirectDisplayID] = [:], workspaces: Int = 8) -> [CGDirectDisplayID: Int] {
        W.syncedDisplays(displayed, displays: displays, workspaces: workspaces) {
            W.homeDisplay(of: $0, movedTo: moved[$0], displays: displays)
        }
    }

    @Test func eachDisplayShowsOneOfItsOwn() {
        #expect(sync([:], [main, top]) == [main: 0, top: 1])
        // A workspace of the main display (5) stays; a foreign one is replaced.
        #expect(sync([main: 4, top: 1], [main, top]) == [main: 4, top: 1])
        #expect(sync([main: 1, top: 1], [main, top]) == [main: 0, top: 1])
        // Unplugging the top display: its entry goes, the main one keeps its workspace.
        #expect(sync([main: 3, top: 1], [main]) == [main: 3])
    }

    @Test func movedWorkspaces() {
        // Workspace 1 moved to the top display, which is the only home of workspace 2 too.
        #expect(sync([main: 0, top: 1], [main, top], moved: [0: top]) == [main: 2, top: 1])
        // Every workspace lives on the top display: the main one shows none, the top its lowest.
        #expect(sync([main: 0], [main, top], moved: [0: top], workspaces: 2) == [top: 0])
    }

    @Test func leftBehind() {
        #expect(W.workspaceLeftBehind(remaining: [0, 2, 3], shownBefore: 3) == 3)
        #expect(W.workspaceLeftBehind(remaining: [0, 2], shownBefore: 5) == 0)
        #expect(W.workspaceLeftBehind(remaining: [], shownBefore: 1) == nil)
    }

    @Test func newWindows() {
        var asked = false
        func appears() -> Int? { asked = true; return 4 }
        #expect(W.newWindowWorkspace(assigned: 6, restored: 2, launch: 1, workspaces: 8, whereItAppears: appears) == 6)
        #expect(W.newWindowWorkspace(assigned: nil, restored: 2, launch: 1, workspaces: 8, whereItAppears: appears) == 2)
        #expect(W.newWindowWorkspace(assigned: nil, restored: nil, launch: 1, workspaces: 8, whereItAppears: appears) == 1)
        #expect(!asked)
        #expect(W.newWindowWorkspace(assigned: 9, restored: nil, launch: nil, workspaces: 8, whereItAppears: appears) == 4)
        #expect(asked)
        #expect(W.newWindowWorkspace(assigned: nil, restored: nil, launch: nil, workspaces: 8) { nil } == 0)
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

/// What the overview and the menu list for a workspace.
@Suite struct WorkspaceSummaryTests {
    @Test func summaryListsEachAppOnceInOrder() {
        let windows = ["Safari", "Terminal", "Safari", "Notes", "Safari"].map {
            WorkspaceSummary.Window(app: $0, title: nil, icon: nil)
        }
        let summary = WorkspaceSummary(index: 0, name: "1", display: nil, windows: windows)
        #expect(summary.apps.map(\.name) == ["Safari", "Terminal", "Notes"])
        #expect(summary.apps.map(\.windows) == [3, 1, 1])
    }
}

/// Which accessibility elements the window manager never tiles.
@Suite struct WindowProbeTests {
    @Test func elementsNeverManagedAreToldFromWindowsNotMovableNow() {
        func probe(_ role: String?, _ subrole: String?, _ kind: AX.WindowProbe.Kind) -> AX.WindowProbe {
            AX.WindowProbe(element: AXUIElementCreateSystemWide(), id: 1, role: role, subrole: subrole, kind: kind,
                           dialogLike: false, title: nil, frame: nil, mainWindow: nil)
        }
        #expect(probe(kAXWindowRole, "AXSheet", .other).isNeverManaged)
        #expect(probe(kAXScrollAreaRole, nil, .other).isNeverManaged)
        // A standard window whose position cannot be set right now may be movable later.
        #expect(!probe(kAXWindowRole, kAXStandardWindowSubrole, .other).isNeverManaged)
        #expect(!probe(kAXWindowRole, kAXStandardWindowSubrole, .standard).isNeverManaged)
        #expect(!probe(kAXWindowRole, nil, .pending).isNeverManaged)
    }
}
