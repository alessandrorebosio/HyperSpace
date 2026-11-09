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

@Suite struct WorkspaceLogicTests {
    typealias W = WindowManager
    let main: CGDirectDisplayID = 1
    let top: CGDirectDisplayID = 2

    @Test func homes() {
        #expect(W.homeDisplay(of: 0, movedTo: nil, displays: [main, top]) == main)
        #expect(W.homeDisplay(of: 1, movedTo: nil, displays: [main, top]) == top)
        #expect(W.homeDisplay(of: 5, movedTo: nil, displays: [main, top]) == main)
        #expect(W.homeDisplay(of: 0, movedTo: top, displays: [main, top]) == top)
        // Moved to a display that was unplugged: back on its own.
        #expect(W.homeDisplay(of: 1, movedTo: 9, displays: [main]) == main)
        #expect(W.homeDisplay(of: 0, movedTo: nil, displays: []) == nil)
    }

    @Test func pinnedDisplay() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let builtIn = ScreenInfo(id: 1, frame: rect, visible: rect, name: "Built-in Retina Display")
        let lg = ScreenInfo(id: 2, frame: rect, visible: rect, name: "LG UltraFine")
        let dell = ScreenInfo(id: 3, frame: rect, visible: rect, name: "DELL U2720Q")
        let screens = [builtIn, lg, dell]
        #expect(ScreenInfo.pinned("main", among: screens)?.id == 1)
        #expect(ScreenInfo.pinned("2", among: screens)?.id == 2)
        #expect(ScreenInfo.pinned("4", among: screens) == nil)
        #expect(ScreenInfo.pinned("dell u2720q", among: screens)?.id == 3)
        #expect(ScreenInfo.pinned("ultrafine", among: screens)?.id == 2)
        #expect(ScreenInfo.pinned("Samsung", among: screens) == nil)
        #expect(ScreenInfo.pinned("", among: screens) == nil)
        #expect(lg.pinValue(among: screens) == "LG UltraFine")
        // Two identical monitors: the name alone cannot tell them apart.
        let twin = ScreenInfo(id: 4, frame: rect, visible: rect, name: "LG UltraFine")
        #expect(lg.pinValue(among: screens + [twin]) == lg.uuid)
        // A pin wins over the default home, and is ignored while its display is unplugged.
        #expect(W.homeDisplay(of: 0, movedTo: ScreenInfo.pinned("3", among: screens)?.id, displays: [1, 2, 3]) == 3)
        #expect(W.homeDisplay(of: 1, movedTo: ScreenInfo.pinned("DELL", among: [builtIn, lg])?.id, displays: [1, 2]) == 2)
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

@Suite struct WorkspaceStateTests {
    @Test func restorerMatchesByTitleThenApp() {
        let state = WorkspaceState(windows: [
            .init(app: "com.apple.Safari", title: "GitHub", workspace: 1),
            .init(app: "com.apple.Safari", title: "Mail", workspace: 2),
            .init(app: "com.spotify.client", title: "Spotify", workspace: 7, floating: true),
        ])
        var restorer = WorkspaceRestorer(state)
        #expect(restorer.claim(app: "com.apple.Safari", title: "Mail") == 1)
        // The tab changed: the next saved Safari window.
        #expect(restorer.claim(app: "com.apple.Safari", title: "Apple") == 0)
        #expect(restorer.claim(app: "com.apple.Safari", title: "GitHub") == nil)
        #expect(restorer.claim(app: "com.microsoft.VSCode", title: nil) == nil)
        #expect(restorer.unclaimed == [state.windows[2]])
        #expect(restorer.window(1).workspace == 2)
    }

    @Test func roundTrip() throws {
        var state = WorkspaceState(windows: [.init(app: "a", title: "t", workspace: 3)],
                                   columns: ["3": [[0]]], displays: ["UUID-1": 3], moved: ["3": "UUID-2"])
        state.savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(WorkspaceState.self, from: encoder.encode(state)) == state)
    }

    @Test func savedColumns() {
        let layout = ColumnLayout(columns: [[10, 11], [], [12]])
        #expect(layout.columns.map(\.windows) == [[10, 11], [12]])
    }
}
