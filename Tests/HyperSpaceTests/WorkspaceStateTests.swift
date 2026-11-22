import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// The saved workspaces (workspaces.json), always in a temporary directory.
@Suite struct WorkspaceStateTests {
    /// A moment in whole seconds: the file keeps dates to the second (ISO 8601).
    private let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func restorerMatchesByTitleThenApp() {
        let state = WorkspaceState(windows: [
            .init(app: "com.apple.Safari", title: "GitHub", workspace: 1),
            .init(app: "com.apple.Safari", title: "Mail", workspace: 2),
            .init(app: "com.spotify.client", title: "Spotify", workspace: 7, floating: true),
        ])
        // Every window there at the start.
        var restorer = WorkspaceRestorer(state, windowsAtStart: [1, 2, 3, 4], appsAtStart: [7])
        #expect(restorer.claim(app: "com.apple.Safari", title: "Mail", window: 1, pid: 7) == 1)
        // The tab changed: the next saved Safari window.
        #expect(restorer.claim(app: "com.apple.Safari", title: "Apple", window: 2, pid: 7) == 0)
        #expect(restorer.claim(app: "com.apple.Safari", title: "GitHub", window: 3, pid: 7) == nil)
        #expect(restorer.claim(app: "com.microsoft.VSCode", title: nil, window: 4, pid: 7) == nil)
        #expect(restorer.unclaimed == [state.windows[2]])
        #expect(restorer.unclaimedIndices == [2])
        #expect(restorer.window(1).workspace == 2)
    }

    /// Every field through the app's own encoder and decoder.
    @Test func roundTrip() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("workspaces.json")
            var state = WorkspaceState(windows: [.init(app: "a", title: "t", workspace: 3),
                                                 .init(app: "b", title: "u", workspace: 1, floating: true),
                                                 .init(app: "c", title: "v", workspace: 1, scratchpad: true)],
                                       columns: ["3": [[0]], "1": [[1], [2]]],
                                       displays: ["UUID-1": 3], moved: ["3": "UUID-2"],
                                       layouts: ["UUID-1": .init(layout: "tall", ratio: 0.6)],
                                       accordions: ["1": [0]], accordionWorkspaces: [2])
            state.savedAt = savedAt
            state.save(to: url)
            let loaded = WorkspaceState.load(now: savedAt + 60, from: url)
            #expect(loaded == state)
            #expect(loaded?.layouts?["UUID-1"]?.ratio == 0.6)
            #expect(loaded?.windows[2].scratchpad == true)
        }
    }

    /// A state a week old or more describes windows long gone.
    @Test func olderThanAWeekIsNotLoaded() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("workspaces.json")
            var state = WorkspaceState(windows: [.init(app: "a", title: "t", workspace: 0)])
            state.savedAt = savedAt
            state.save(to: url)
            #expect(WorkspaceState.maxAge == 7 * 24 * 3600)
            #expect(WorkspaceState.load(now: savedAt + WorkspaceState.maxAge - 1, from: url) == state)
            #expect(WorkspaceState.load(now: savedAt + WorkspaceState.maxAge, from: url) == nil)
        }
    }

    /// A file written before the optional keys existed still loads.
    @Test func anOlderFileWithoutTheOptionalKeysLoads() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("workspaces.json")
            try #"""
            { "savedAt": "2027-01-15T08:00:00Z",
              "windows": [ { "app": "com.apple.Safari", "title": "GitHub", "workspace": 1 } ],
              "columns": { "1": [ [0] ] } }
            """#.write(to: url, atomically: true, encoding: .utf8)
            let date = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
            let state = try #require(WorkspaceState.load(now: date + 60, from: url))
            #expect(state.savedAt == date)
            #expect(state.windows == [.init(app: "com.apple.Safari", title: "GitHub", workspace: 1)])
            #expect(state.windows[0].floating == nil && state.windows[0].scratchpad == nil)
            #expect(state.columns == ["1": [[0]]])
            #expect(state.displays == nil && state.moved == nil && state.layouts == nil)
            #expect(state.accordions == nil && state.accordionWorkspaces == nil)
        }
    }

    @Test func aMissingOrBrokenFileIsNoState() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("workspaces.json")
            #expect(WorkspaceState.load(now: savedAt, from: url) == nil)
            try "{ \"windows\": ".write(to: url, atomically: true, encoding: .utf8)
            #expect(WorkspaceState.load(now: savedAt, from: url) == nil)
            // A required key missing.
            try #"{ "savedAt": "2027-01-15T08:00:00Z", "columns": {} }"#.write(to: url, atomically: true, encoding: .utf8)
            #expect(WorkspaceState.load(now: savedAt, from: url) == nil)
        }
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
}

/// What is saved when HyperSpace quits before every saved window was found again.
@Suite struct SavedStateTests {
    @Test func unclaimedWindowsKeepTheirColumnsOnAnEarlyQuit() {
        var saved = WorkspaceState()
        saved.windows = ["a", "b", "c", "d"].map { .init(app: $0, title: "", workspace: 1) }
        saved.columns = ["1": [[0, 1], [2], [3]]]
        var now = WorkspaceState()
        now.windows = [.init(app: "c", title: "", workspace: 1)]
        now.columns = ["1": [[0]]]
        // a and b (one column) and d were not found again yet.
        let kept = WindowManager.keepingUnclaimed([0, 1, 3], of: saved, in: now)
        #expect(kept.windows.map(\.app) == ["c", "a", "b", "d"])
        #expect(kept.columns["1"] == [[0], [1, 2], [3]])
    }
}
