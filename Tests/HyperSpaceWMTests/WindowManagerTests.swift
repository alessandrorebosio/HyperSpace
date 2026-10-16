import CoreGraphics
import Foundation
import HyperSpaceCore
@testable import HyperSpaceWM
import Testing

/// The service end to end: events from a fake app in, frames out.
@MainActor
struct WindowManagerTests {
    static let main = WMMonitor(id: 1, name: "Built-in", isMain: true, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                visible: CGRect(x: 0, y: 0, width: 1000, height: 600))
    static let dell = WMMonitor(id: 2, name: "DELL", frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                                visible: CGRect(x: 1000, y: 0, width: 800, height: 600))
    static let left = CGRect(x: 0, y: 0, width: 500, height: 600)
    static let right = CGRect(x: 500, y: 0, width: 500, height: 600)
    static let full = CGRect(x: 0, y: 0, width: 1000, height: 600)
    /// Where hidden windows wait: the main monitor's bottom right corner.
    static let corner = CGPoint(x: 999, y: 599)

    private func window(_ id: WindowID, _ frame: CGRect = CGRect(x: 100, y: 100, width: 300, height: 200)) -> WindowRecord {
        WindowRecord(id: id, floating: false, frame: frame, title: "window \(id)")
    }

    private func started(_ system: FakeSystem) -> WindowManager {
        let wm = WindowManager.fake(system)
        wm.start(WMSettings())
        return wm
    }

    @Test func windowsAreTiledFromTheStart() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        #expect(Set([app.frames[1], app.frames[2]]) == [Self.left, Self.right])
        app.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(app.frames.values.allSatisfy { $0.width == 333 || $0.width == 334 }, "three tiles")
        app.destroy(3)
        #expect(Set([app.frames[1], app.frames[2]]) == [Self.left, Self.right])
        #expect(wm.run(words: ["list-windows", "--all", "--count"]).output == "2")
    }

    @Test func hiddenWorkspacesWaitInTheCorner() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        app.focused = 2
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        #expect(wm.run("move-node-to-workspace 2") == nil)
        #expect(app.frames[1] == Self.full)
        #expect(app.frames[2]?.origin == Self.corner)
        #expect(wm.run("workspace 2") == nil)
        #expect(app.frames[2] == Self.full && app.frames[1]?.origin == Self.corner)
        #expect(app.raised.last == 2, "the shown workspace's window is focused")
    }

    @Test func nativeTabsShareOneTile() {
        let app = FakeApp(pid: 10, bundleID: "com.apple.finder", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        let tile = app.frames[1]!
        // A new tab: on its group's frame, shown, while the tab it replaces goes off screen.
        app.offscreen = [1]
        app.create(3, frame: tile)
        #expect(app.frames[2] == Self.right, "the other window keeps its tile")
        #expect(wm.run(words: ["list-windows", "--all", "--count"]).output == "2", "a tab is not a window of its own")
        // Tabs made faster than their events: this one is already behind a later tab.
        app.offscreen = [1, 3, 4]
        app.create(4, frame: tile)
        app.create(5, frame: tile)
        #expect(app.frames[2] == Self.right)
        #expect(Set([1, 3, 4, 5].map { app.frames[$0] }) == [tile], "tabs follow their group")
        // The group's window closes: another tab stands in, in the same tile.
        app.destroy(1)
        app.offscreen = [3, 4]
        app.destroy(5)
        #expect(app.frames[2] == Self.right && app.frames[3] == tile)
        #expect(wm.run(words: ["list-windows", "--all", "--format", "%{window-id}"]).output.split(separator: "\n").sorted() == ["2", "3"])
    }

    @Test func layoutComesBackAfterARestart() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2), window(3)])
        app.focused = 3
        let system = FakeSystem(screens: [Self.main], apps: [app])
        let wm = started(system)
        #expect(wm.run("move-node-to-workspace 7") == nil)
        #expect(wm.run("layout floating tiling --window-id 2") == nil)
        wm.stop()
        #expect(FileManager.default.fileExists(atPath: system.layoutURL.path))

        let again = started(system)
        #expect(again.run("workspace 7") == nil)
        #expect(app.frames[3] == Self.full, "window 3 is alone on workspace 7")
        #expect(again.run("workspace 1") == nil)
        #expect(app.frames[1] == Self.full, "window 2 floats: window 1 has the workspace")
    }

    @Test func layoutWaitsForEveryAppPresentAtLaunch() {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(3)])
        let system = FakeSystem(screens: [Self.main], apps: [a, b])
        let first = started(system)
        #expect(first.run("move-node-to-workspace 7 --window-id 3") == nil)
        first.stop()

        b.slowStart = true
        let wm = started(system)
        // Other apps coming and going meanwhile don't end the startup.
        system.send(.activated(99))
        system.send(.launched(98))
        #expect(wm.isStartingUp)
        b.finishStart()
        #expect(!wm.isStartingUp)
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "3",
                "the slow app's window is put back too")
    }

    @Test func anAppQuittingDuringStartupDoesNotHoldItUp() {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(2)])
        b.slowStart = true
        let system = FakeSystem(screens: [Self.main], apps: [a, b])
        let wm = started(system)
        #expect(wm.isStartingUp)
        system.apps[11] = nil
        system.send(.terminated(11))
        #expect(!wm.isStartingUp)
        #expect(a.frames[1] == Self.full)
        wm.stop()
    }

    @Test func windowsOfADisplayThatLeftStayReachable() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2, CGRect(x: 1100, y: 100, width: 300, height: 200))])
        let system = FakeSystem(screens: [Self.main, Self.dell], apps: [app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(app.frames[2] == Self.dell.visible, "on the display it was on")
        system.screens = [Self.main]
        system.send(.displaysChanged)
        #expect(app.frames[2]?.origin == Self.corner, "parked on a display that is there")
        system.screens = [Self.main, Self.dell]
        system.send(.displaysChanged)
        #expect(app.frames[2] == Self.dell.visible, "back on its display")
    }

    @Test func appsCaughtWhenTheyFirstActivate() {
        let system = FakeSystem(screens: [Self.main])
        let wm = started(system)
        defer { wm.stop() }
        // Not a regular app when it launched: first seen when it becomes active.
        let app = FakeApp(pid: 11, bundleID: "new", windows: [window(1)])
        system.apps[11] = app
        system.send(.activated(11))
        #expect(app.frames[1] == Self.full)
    }

    @Test func anAppOpenedAgainGoesBackToItsWorkspace() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        system.apps[11] = nil
        system.send(.terminated(11))
        #expect(wm.focusedWorkspace == "1")

        // Launched again from workspace 1: its window goes to 7, and so does focus.
        let again = FakeApp(pid: 12, bundleID: "app")
        system.apps[12] = again
        system.frontmost = 12
        system.send(.launched(12))
        again.focused = 3
        again.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "3")
        #expect(wm.focusedWorkspace == "7")

        // A second window while it's open joins the focused workspace as usual.
        #expect(wm.run("workspace 1") == nil)
        system.frontmost = 10
        again.create(4, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(wm.run(words: ["list-windows", "--workspace", "1", "--format", "%{window-id}"]).output.contains("4"))
    }

    @Test func theWorkspaceIsRememberedWhenTheLastWindowCloses() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.destroy(2)
        app.initial = []
        wm.stop()

        // Across a restart too.
        let restarted = started(system)
        defer { restarted.stop() }
        app.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(restarted.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "3")
        #expect(restarted.focusedWorkspace == "1", "opened in the background: focus stays")
    }

    /// Where a new scratchpad goes on the main monitor: 80% of it, centered.
    static let scratchpadFrame = CGRect(x: 100, y: 60, width: 800, height: 480)

    @Test func scratchpadComesAndGoes() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Shell --window-id 2") == nil)
        #expect(wm.run("focus --window-id 1") == nil)

        // Summoned: floating over workspace 1, centered, focused; its old workspace is gone.
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.focusedWorkspace == "1")
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(other.frames[1] == Self.full, "the tiles don't move")
        #expect(term.raised.last == 2)
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-layout}"]).output == "floating")
        #expect(wm.run(words: ["list-workspaces", "--empty", "no"]).output == "1")

        // Put away: in the corner, focus back on the window before.
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2]?.origin == Self.corner)
        #expect(other.raised.last == 1)
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output == "1")

        // Summoned on another workspace: it comes there, where it was on screen.
        #expect(wm.run("workspace 2") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(wm.run(words: ["list-windows", "--workspace", "2", "--format", "%{window-id}"]).output == "2")

        // Shown but not focused: the key focuses it instead of hiding it.
        #expect(wm.run("workspace 1") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.focusedWorkspace == "1" && term.frames[2] == Self.scratchpadFrame)
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output == "2")
    }

    @Test func scratchpadOpensItsAppWhenItHasNoWindow() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let system = FakeSystem(screens: [Self.main], apps: [other])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("scratchpad term") == nil)
        #expect(system.opened == ["term"])

        let term = FakeApp(pid: 11, bundleID: "term")
        system.apps[11] = term
        system.send(.launched(11))
        term.create(2, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(other.frames[1] == Self.full)
        #expect(term.raised.last == 2)

        // Its next window is an ordinary one.
        term.create(3, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(term.frames[3] == Self.right)
    }

    @Test func aStashedScratchpadComesBackWhenMacOSFocusesIt() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(other.frames[1] == Self.full)

        // ⌘-Tab to the app: its window was stashed, so it's summoned.
        term.focused = 2
        system.frontmost = 11
        system.send(.activated(11))
        #expect(term.frames[2] == Self.scratchpadFrame)

        // Closed while stashed: nothing is left of it.
        #expect(wm.run("scratchpad term") == nil)
        term.destroy(2)
        #expect(wm.run(words: ["list-windows", "--all", "--count"]).output == "1")
    }

    /// Workspace 1 has windows 1 (app 10) and 3 (app 12, focused); workspace O has window 2
    /// (app 11), whose app macOS activates when window 3 closes.
    private func closingSetup() -> (FakeSystem, WindowManager, FakeApp, FakeApp, FakeApp) {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(2)])
        let c = FakeApp(pid: 12, bundleID: "c", windows: [window(3)])
        let system = FakeSystem(screens: [Self.main], apps: [a, b, c])
        let wm = started(system)
        _ = wm.run("move-node-to-workspace O --window-id 2")
        _ = wm.run("focus --window-id 3")
        b.focused = 2
        return (system, wm, a, b, c)
    }

    @Test func closingTheFocusedWindowKeepsTheWorkspace() {
        // Reported before macOS activates the app used before.
        let (system, wm, a, _, c) = closingSetup()
        defer { wm.stop() }
        c.destroy(3)
        system.frontmost = 11
        system.send(.activated(11))
        #expect(wm.focusedWorkspace == "1")
        #expect(a.raised.last == 1, "focus goes to the workspace's next window")
    }

    @Test func closingTheFocusedWindowKeepsTheWorkspaceWhenReportedLate() {
        // macOS activates the other app before the close is reported (an app quitting).
        let (system, wm, a, _, c) = closingSetup()
        defer { wm.stop() }
        c.frames[3] = nil
        system.apps[12] = nil
        system.frontmost = 11
        system.send(.activated(11))
        #expect(wm.focusedWorkspace == "1")
        system.send(.terminated(12))
        #expect(wm.focusedWorkspace == "1")
        #expect(a.raised.last == 1)
    }

    @Test func activatingAnAppStillShowsItsWorkspace() {
        let (system, wm, _, _, _) = closingSetup()
        defer { wm.stop() }
        system.frontmost = 11
        system.send(.activated(11))
        #expect(wm.focusedWorkspace == "O", "⌘-Tab to an app: its workspace is shown")
    }

    @Test func draggedTiledWindowsGoBack() async throws {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        let tile = app.frames[1]!
        // Our own moves settle within a second: wait past that, then drag.
        try await Task.sleep(for: .milliseconds(1100))
        app.frames[1] = CGRect(x: 200, y: 200, width: 400, height: 300)
        app.send(.moved(1))
        try await Task.sleep(for: .milliseconds(400))
        #expect(app.frames[1] == tile)
        _ = wm
    }

    @Test func missedWindowsAreCaughtOnFocus() async throws {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        // A window appears and another closes without their events.
        app.miss(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        app.frames[2] = nil
        app.send(.focusChanged)
        #expect(app.frames[3] == CGRect(x: 10, y: 10, width: 100, height: 100), "not on the switch's path: a moment later")
        try await Task.sleep(for: .milliseconds(1200))
        #expect(Set([app.frames[1], app.frames[3]]) == [Self.left, Self.right])
        #expect(wm.run(words: ["list-windows", "--all", "--count"]).output == "2")
    }

    @Test func lostFramesAreSetAgain() async throws {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        app.dropNextFrame = [1]
        app.create(2, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(app.frames[1] == Self.full, "the busy app missed its new frame")
        try await Task.sleep(for: .milliseconds(400))
        #expect(Set([app.frames[1], app.frames[2]]) == [Self.left, Self.right])
        _ = wm
    }

    @Test func menuBarShowsEveryDisplaysWorkspace() {
        // An external display left of the main one: the main display still comes first.
        let external = WMMonitor(id: 2, name: "DELL", frame: CGRect(x: -800, y: 0, width: 800, height: 600),
                                 visible: CGRect(x: -800, y: 0, width: 800, height: 600))
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2, CGRect(x: -700, y: 100, width: 300, height: 200))])
        app.focused = 2
        let system = FakeSystem(screens: [external, Self.main], apps: [app])
        var changes = 0
        let wm = WindowManager(handlers: .init(reloadConfig: {}, enable: { _ in }, modeChanged: { _ in }, mediaKey: { _ in },
                                               changed: { changes += 1 }), system: system)
        wm.start(WMSettings())
        defer { wm.stop() }
        let shown = wm.shownWorkspaces
        #expect(shown.count == 2)
        #expect(shown.map(\.focused) == [false, true], "the focused window is on the external display, second")
        let before = changes
        #expect(wm.run("focus-monitor right") == nil)
        #expect(wm.shownWorkspaces.map(\.focused) == [true, false])
        #expect(changes == before + 1)
        #expect(wm.run("focus-monitor right") != nil || changes == before + 1, "nothing changed, nothing redrawn")
    }
}
