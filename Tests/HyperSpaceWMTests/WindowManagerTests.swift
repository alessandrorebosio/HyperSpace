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

    @Test func missedWindowsAreCaughtOnFocus() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        // A window appears and another closes without their events.
        app.miss(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        app.frames[2] = nil
        app.send(.focusChanged)
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
