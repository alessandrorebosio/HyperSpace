import CoreGraphics
import Foundation
@testable import HyperSpaceCore
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

    private func started(_ system: FakeSystem, _ settings: WMSettings = WMSettings()) -> WindowManager {
        let wm = WindowManager.fake(system)
        wm.start(settings)
        return wm
    }

    /// reopen-apps-in-last-workspace = true
    private static let reopening = {
        var settings = WMSettings()
        settings.reopenAppsInLastWorkspace = true
        return settings
    }()

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

    @Test func windowsWaitForTheSavedLayoutWithoutPassingTiles() {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(3)])
        let system = FakeSystem(screens: [Self.main], apps: [a, b])
        let first = started(system)
        #expect(first.run("move-node-to-workspace 7 --window-id 3") == nil)
        first.stop()
        let back = b.frames[3]!
        #expect(back.origin != Self.corner, "given back on screen")

        b.slowStart = true
        let wm = started(system)
        defer { wm.stop() }
        a.frames[1] = CGRect(x: 1, y: 1, width: 10, height: 10) // moved meanwhile: shows a set frame
        #expect(wm.isStartingUp)
        #expect(a.frames[1] == CGRect(x: 1, y: 1, width: 10, height: 10) && b.frames[3] == back, "nothing set yet")
        b.finishStart()
        #expect(Set([a.frames[1], a.frames[2]]) == [Self.left, Self.right])
        #expect(b.frames[3] == CGRect(origin: Self.corner, size: back.size), "back on its hidden workspace, at its size")
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

    @Test func anIgnoredDisplayIsAsIfDisconnected() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2, CGRect(x: 1100, y: 100, width: 300, height: 200))])
        let system = FakeSystem(screens: [Self.main, Self.dell], apps: [app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run(words: ["ignore-monitor", "on", "dell"]).ok)
        #expect(app.frames[2]?.origin == Self.corner, "its workspace waits on the main display")
        #expect(wm.run(words: ["list-monitors", "--count"]).output == "1")
        #expect(wm.run(words: ["list-monitors", "--all", "--format", "%{monitor-name} %{monitor-is-ignored}"]).output == "Built-in false\nDELL true")
        #expect(wm.displays.map(\.ignored) == [false, true])
        #expect(wm.run(words: ["ignore-monitor", "toggle", "dell"]).ok)
        #expect(app.frames[2] == Self.dell.visible, "back on its display")
        #expect(wm.run(words: ["ignore-monitor", "on", "dell", "main"]).error?.contains("every monitor") == true)
        #expect(wm.run(words: ["list-monitors", "--count"]).output == "2", "nothing left out")
        #expect(wm.run(words: ["ignore-monitor", "on", "lg"]).error?.contains("no monitor matches") == true)
    }

    @Test func subscribersGetFocusAndModeEvents() throws {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        defer { wm.stop() }
        var events: [String] = []
        wm.onEvent = { _, line in events.append(line) }
        let subscription = try wm.subscribe(["focused-workspace-changed", "mode-changed"])
        #expect(subscription.initial.contains(#""_event":"focused-workspace-changed""#))
        #expect(wm.run(words: ["workspace", "2"]).ok)
        #expect(events.contains(#"{"_event":"focused-workspace-changed","prevWorkspace":"1","workspace":"2"}"#))
        app.create(2, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(events.contains { $0.contains(#""_event":"window-detected""#) && $0.contains(#""windowId":2"#) })
        #expect(try wm.subscribe(["--all", "--no-send-initial"]).initial.isEmpty)
        #expect(throws: InvalidConfig.self) { try wm.subscribe(["binding-triggered"]) }
        #expect(throws: InvalidConfig.self) { try wm.subscribe([]) }
    }

    @Test func aModeShowsItsBindingsWhenAsked() throws {
        let wm = WindowManager.fake(FakeSystem(screens: [Self.main]))
        var settings = try WMSettings(ConfigLoader.parse(WMConfig.self, "[mode.main.binding]\nalt-s = 'mode service'\n[mode.service.binding]\nesc = 'mode main'").get())
        wm.start(settings)
        defer { wm.stop() }
        #expect(wm.run(words: ["mode", "service"]).ok)
        #expect(wm.shownBindings == nil, "off by default")
        settings.showModeBindings = true
        wm.start(settings)
        #expect(wm.shownBindings?.map(\.key) == ["esc"])
        #expect(wm.run(words: ["mode", "main"]).ok)
        #expect(wm.shownBindings == nil)
    }

    @Test func displaySettingsGoToTheFocusedOrNamedDisplay() {
        let system = FakeSystem(screens: [Self.main, Self.dell])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run(words: ["monitor-brightness", "+10"]).ok)
        #expect(wm.run(words: ["monitor-input", "hdmi1", "--monitor", "dell"]).ok)
        #expect(system.settings.map(\.id) == [1, 2])
        #expect(system.settings.map(\.setting) == [.brightness(.add(10)), .input(0x11)])
        #expect(wm.run(words: ["monitor-volume", "50", "--monitor", "lg"]).error?.contains("no monitor matches") == true)
    }

    @Test func aDisplayShowingAnotherInputIsLeftOut() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2, CGRect(x: 1100, y: 100, width: 300, height: 200))])
        let system = FakeSystem(screens: [Self.main, Self.dell], apps: [app])
        system.inputs = [2: 0x1b]
        let wm = WindowManager.fake(system)
        var settings = WMSettings()
        settings.detectMonitorInput = true
        wm.start(settings)
        defer { wm.stop() }
        wm.readMonitorInputs()
        #expect(wm.macInputs["DELL"] == nil, "at launch it may be showing another computer")
        system.inputs = [2: 0x0f]
        wm.readMonitorInputs()
        #expect(app.frames[2] == Self.dell.visible, "shown until the Mac's input is known")
        // Plugged in: it shows the Mac.
        system.screens = [Self.main]
        system.send(.displaysChanged)
        system.screens = [Self.main, Self.dell]
        system.inputs = [2: 0x1b]
        system.send(.displaysChanged)
        #expect(wm.macInputs["DELL"] == 0x1b, "learned when plugged in")
        #expect(app.frames[2] == Self.dell.visible)
        system.inputs = [2: 0x0f]
        wm.readMonitorInputs()
        #expect(app.frames[2]?.origin == Self.corner, "switched to another computer")
        system.inputs = [:]
        wm.readMonitorInputs()
        #expect(app.frames[2]?.origin == Self.corner, "a missed read changes nothing")
        system.inputs = [2: 0x1b]
        wm.readMonitorInputs()
        #expect(app.frames[2] == Self.dell.visible, "back to the Mac")
        // Taken back while on another input: that one is the Mac's from now on.
        system.inputs = [2: 0x0f]
        wm.readMonitorInputs()
        #expect(wm.run(words: ["ignore-monitor", "off", "dell"]).ok)
        #expect(wm.macInputs["DELL"] == 0x0f)
        #expect(app.frames[2] == Self.dell.visible)
        // Turned off: every display is shown, whatever its input.
        system.inputs = [2: 0x1b]
        wm.readMonitorInputs()
        #expect(app.frames[2]?.origin == Self.corner)
        wm.start(WMSettings())
        #expect(app.frames[2] == Self.dell.visible)
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

    @Test func anAppOpenedAgainOpensOnTheFocusedWorkspace() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        system.apps[11] = nil
        system.send(.terminated(11))

        // Launched again from workspace 1: it stays there, off by default.
        let again = FakeApp(pid: 12, bundleID: "app")
        system.apps[12] = again
        system.frontmost = 12
        system.send(.launched(12))
        again.focused = 3
        again.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(wm.run(words: ["list-windows", "--workspace", "1", "--format", "%{window-id}"]).output.contains("3"))
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--count"]).output == "0")
        #expect(wm.focusedWorkspace == "1")
    }

    @Test func aRuleWinsOverTheWorkspaceAnAppWasLastOn() throws {
        for reopen in [false, true] {
            let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
            let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
            let system = FakeSystem(screens: [Self.main], apps: [other, app])
            var settings = try WMSettings(ConfigLoader.parse(WMConfig.self, """
            [[on-window-detected]]
                if.app-id = 'app'
                run = 'move-node-to-workspace 5'
            """).get())
            settings.reopenAppsInLastWorkspace = reopen
            let wm = started(system, settings)
            #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
            app.destroy(2)
            app.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
            #expect(wm.run(words: ["list-windows", "--workspace", "5", "--format", "%{window-id}"]).output == "3",
                    "reopen-apps-in-last-workspace = \(reopen)")
            wm.stop()
        }
    }

    @Test func anAppOpenedAgainGoesBackToItsWorkspaceWhenAsked() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system, Self.reopening)
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

    @Test func aMinimizedWindowComesBackToItsWorkspace() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.send(.minimized(2, true))
        #expect(!wm.run(words: ["list-workspaces", "--all"]).output.contains("7"), "out of the layout")

        // Restored while on workspace 1, in the background: back on 7, focus stays.
        app.send(.minimized(2, false))
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "2")
        #expect(wm.focusedWorkspace == "1")

        // From the Dock, the app in front: focus follows it.
        app.send(.minimized(2, true))
        system.frontmost = 11
        app.focused = 2
        app.send(.minimized(2, false))
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "2")
        #expect(wm.focusedWorkspace == "7")
    }

    @Test func aMinimizedWindowComesBackToItsSpotInTheTree() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        defer { wm.stop() }
        #expect(app.frames[1] == Self.left && app.frames[2] == Self.right)
        #expect(wm.run("focus --window-id 2") == nil)
        #expect(wm.run("resize width -100 --window-id 1") == nil)
        let narrowed = app.frames[1]
        app.send(.minimized(1, true))
        #expect(app.frames[2] == Self.full)

        // Left of 2 again, at its width, not after the focused window.
        app.send(.minimized(1, false))
        #expect(app.frames[1] == narrowed)
        #expect(app.frames[2].map { $0.minX == narrowed?.maxX } == true)
    }

    @Test func aWindowInMacOSFullScreenLeavesTheLayoutAndComesBack() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        defer { wm.stop() }
        #expect(app.frames[1] == Self.left && app.frames[2] == Self.right)
        app.send(.nativeFullscreen(1, true))
        #expect(app.frames[2] == Self.full, "its tile closes")
        let onItsSpace = CGRect(x: 0, y: 0, width: 1000, height: 600)
        app.frames[1] = onItsSpace
        // Not parked on a workspace switch, not put back in a tile.
        #expect(wm.run("workspace 2") == nil)
        #expect(app.frames[1] == onItsSpace)
        #expect(wm.run("workspace 1") == nil)

        app.send(.nativeFullscreen(1, false))
        #expect(app.frames[1] == Self.left && app.frames[2] == Self.right)
    }

    @Test func focusOnAFullScreenSpaceKeepsTheWorkspace() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 3 --window-id 2") == nil)
        app.send(.nativeFullscreen(1, true))
        // Its Space shown: the app's other window must not take us to workspace 3.
        app.focused = 1
        system.send(.activated(10))
        #expect(wm.focusedWorkspace == "1")
    }

    @Test func aWindowAlreadyInMacOSFullScreenIsNotTiled() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1),
                                                            WindowRecord(id: 2, floating: false, frame: Self.full, title: "", fullscreen: true)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        defer { wm.stop() }
        #expect(app.frames[1] == Self.full)
        #expect(wm.run(words: ["list-windows", "--all", "--format", "%{window-id} %{window-is-macos-fullscreen}"]).output == "1 false\n2 true")
        // Out of full screen: at the spot it would have had.
        app.frames[2] = Self.left
        app.send(.nativeFullscreen(2, false))
        #expect(app.frames[1] == Self.left && app.frames[2] == Self.right)
        #expect(wm.run(words: ["list-windows", "--all", "--format", "%{window-is-macos-fullscreen}"]).output == "false\nfalse")
    }

    @Test func aWindowOpenedInMacOSFullScreenFollowsTheRules() throws {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app")
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = WindowManager.fake(system)
        wm.start(try WMSettings(ConfigLoader.parse(WMConfig.self, """
        [[on-window-detected]]
            if.app-id = 'app'
            run = 'move-node-to-workspace 5'
        """).get()))
        defer { wm.stop() }
        app.create(2, frame: Self.full, fullscreen: true)
        #expect(other.frames[1] == Self.full)
        #expect(wm.run(words: ["list-windows", "--workspace", "5", "--format", "%{window-id}"]).output == "2")
        app.send(.nativeFullscreen(2, false))
        #expect(wm.run(words: ["list-windows", "--workspace", "5", "--format", "%{window-is-macos-fullscreen}"]).output == "false")
        #expect(wm.focusedWorkspace == "1")
    }

    @Test func windowsSetAsideAreListedWithTheirWorkspace() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [other, app]))
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.send(.minimized(2, true))
        // Workspace 7 is gone (empty), its minimized window is still listed with it.
        #expect(wm.run(words: ["list-workspaces", "--all"]).output.contains("7") == false)
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "2")
        #expect(wm.run(words: ["list-windows", "--all", "--format", "%{window-id} %{workspace}"]).output == "1 1\n2 7")
        #expect(wm.run(words: ["list-windows", "--app-bundle-id", "app", "--count"]).output == "1")
    }

    @Test func aFullscreenTileStaysFullscreenThroughAMinimize() {
        let app = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [app]))
        defer { wm.stop() }
        #expect(wm.run("fullscreen on --window-id 1") == nil)
        #expect(app.frames[1] == Self.full)
        app.send(.minimized(1, true))
        app.send(.minimized(1, false))
        #expect(app.frames[1] == Self.full)
        #expect(wm.run(words: ["list-windows", "--all", "--format", "%{window-id} %{window-is-fullscreen}"]).output.contains("1 true"))
    }

    @Test func aMinimizedWindowKeepsItsSpotAcrossARestart() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.send(.minimized(2, true))
        wm.stop()

        // Minimized windows aren't reported at launch: found later, when restored.
        app.initial = []
        let restarted = started(system)
        defer { restarted.stop() }
        app.create(2, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(restarted.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "2")

        // Not for another app's window with the same id (after a reboot).
        app.send(.minimized(2, true))
        restarted.stop()
        let third = started(system)
        defer { third.stop() }
        #expect(third.setAside[2] != nil)
        let stranger = FakeApp(pid: 12, bundleID: "stranger")
        system.apps[12] = stranger
        system.send(.launched(12))
        stranger.create(2, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(third.run(words: ["list-windows", "--workspace", "1", "--format", "%{window-id}"]).output.contains("2"))
    }

    @Test func aMinimizedWindowDoesNotMakeAnAppReopened() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system, Self.reopening)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.send(.minimized(2, true))
        // Still open (minimized): a new window joins the focused workspace.
        app.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(wm.run(words: ["list-windows", "--workspace", "1", "--format", "%{window-id}"]).output.contains("3"))
    }

    @Test func uninstalledAppsAreForgotten() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "gone", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        system.apps[11] = nil
        system.send(.terminated(11))
        #expect(wm.appWorkspaces["gone"] == "7")
        wm.stop()

        system.uninstalled = ["gone"]
        let restarted = started(system)
        defer { restarted.stop() }
        #expect(restarted.appWorkspaces["gone"] == nil)
        restarted.stop()
        #expect(restarted.loadAppWorkspaces()["gone"] == nil, "and off the disk")
    }

    @Test func framesTakeTheFewestCallsThatStayOnScreen() {
        let a = CGRect(x: 0, y: 0, width: 500, height: 600), b = CGRect(x: 500, y: 0, width: 400, height: 300)
        #expect(AX.frameSteps(b, old: a) == [.size, .position], "shrinking")
        #expect(AX.frameSteps(a, old: b) == [.position, .size], "growing")
        #expect(AX.frameSteps(CGRect(x: 10, y: 0, width: 600, height: 200), old: a) == [.size, .position, .size])
        #expect(AX.frameSteps(b, old: nil) == [.size, .position, .size])
        #expect(AX.frameSteps(a.offsetBy(dx: 10, dy: 0), old: a) == [.position])
        #expect(AX.frameSteps(CGRect(x: 0, y: 0, width: 300, height: 600), old: a) == [.size])
        #expect(AX.frameSteps(a, old: a).isEmpty)
    }

    @Test func aHiddenAppsWindowsComeBackToTheirWorkspaces() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2), window(3)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        #expect(wm.run("move-node-to-workspace 8 --window-id 3") == nil)
        system.send(.hidden(11, true))
        #expect(wm.run(words: ["list-workspaces", "--all"]).output == "1", "out of the layout")
        system.send(.hidden(11, false))
        #expect(wm.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "2")
        #expect(wm.run(words: ["list-windows", "--workspace", "8", "--format", "%{window-id}"]).output == "3")
        #expect(wm.focusedWorkspace == "1")
    }

    @Test func theWorkspaceIsRememberedWhenTheLastWindowCloses() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let app = FakeApp(pid: 11, bundleID: "app", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, app])
        let wm = started(system, Self.reopening)
        #expect(wm.run("move-node-to-workspace 7 --window-id 2") == nil)
        app.destroy(2)
        app.initial = []
        wm.stop()

        // Across a restart too.
        let restarted = started(system, Self.reopening)
        defer { restarted.stop() }
        app.create(3, frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(restarted.run(words: ["list-windows", "--workspace", "7", "--format", "%{window-id}"]).output == "3")
        #expect(restarted.focusedWorkspace == "1", "opened in the background: focus stays")
    }

    @Test func aLateActivationOfTheWindowJustLeftDoesNotSwitchBack() {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(2)])
        a.focused = 1
        b.focused = 2
        let system = FakeSystem(screens: [Self.main], apps: [a, b])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace 2 --window-id 2") == nil)
        #expect(wm.run("focus --window-id 1") == nil)
        #expect(wm.run("workspace 2") == nil)
        #expect(wm.run("workspace 3") == nil, "empty, nothing to focus there")
        // The activation of window 2, the one `workspace 3` left, arrives only now.
        system.frontmost = 11
        system.send(.activated(11))
        #expect(wm.focusedWorkspace == "3")
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
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-is-scratchpad} %{window-scratchpad-home}"]).output == "true Shell")
        #expect(wm.run(words: ["list-workspaces", "--empty", "no"]).output == "1")

        // Put away: back on Shell (hidden, so in the corner), focus back on the window before.
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2]?.origin == Self.corner)
        #expect(other.raised.last == 1)
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output == "1")

        // Summoned on another workspace: it comes there, centered again.
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

    @Test func theScratchpadAlwaysComesBackAtItsSize() async throws {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let wm = started(FakeSystem(screens: [Self.main], apps: [other, term]))
        defer { wm.stop() }
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2] == Self.scratchpadFrame)
        // The user drags and resizes it, past our own moves settling.
        try await Task.sleep(for: .milliseconds(1100))
        term.frames[2] = CGRect(x: 20, y: 30, width: 300, height: 200)
        term.send(.moved(2))
        try await Task.sleep(for: .milliseconds(400))
        #expect(term.frames[2] == CGRect(x: 20, y: 30, width: 300, height: 200), "a floating window keeps what it's given")
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2] == Self.scratchpadFrame, "centered at its size again")
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

    /// The ids of a workspace's windows, in order.
    private func ids(_ wm: WindowManager, _ workspace: String) -> String {
        wm.run(words: ["list-windows", "--workspace", workspace, "--format", "%{window-id}"]).output
    }

    @Test func anOpenedScratchpadIsPutAwayWhereItsAppBelongs() throws {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term")
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = WindowManager.fake(system)
        wm.start(try WMSettings(ConfigLoader.parse(WMConfig.self, """
        [[on-window-detected]]
            if.app-id = 'term'
            run = 'move-node-to-workspace Shell'
        """).get()))
        defer { wm.stop() }

        // A rule: where it sends the app's windows.
        #expect(wm.run("scratchpad term") == nil)
        term.create(2, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(wm.focusedWorkspace == "1" && term.frames[2] == Self.scratchpadFrame)
        #expect(wm.run("scratchpad term") == nil)
        #expect(ids(wm, "Shell") == "2" && term.frames[2]?.origin == Self.corner)

        // No rule: where the app was last. It was on Shell when its last window closed.
        wm.start(WMSettings())
        term.destroy(2)
        #expect(wm.run("scratchpad term") == nil)
        term.create(3, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(wm.focusedWorkspace == "1" && term.frames[3] == Self.scratchpadFrame)
        #expect(wm.run("scratchpad term") == nil)
        #expect(ids(wm, "Shell") == "3")
    }

    @Test func anOpenedScratchpadWithNowhereToGoIsPutAwayOnTheFallbackWorkspace() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let system = FakeSystem(screens: [Self.main], apps: [other])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("scratchpad term") == nil)
        let term = FakeApp(pid: 11, bundleID: "term")
        system.apps[11] = term
        system.send(.launched(11))
        term.create(2, frame: CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(wm.run("scratchpad term") == nil)
        #expect(ids(wm, "Scratch") == "2" && ids(wm, "1") == "1")
        #expect(other.frames[1] == Self.full)

        // Summoned and put away again: it went home to Scratch, so it goes back there.
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(wm.run("scratchpad term") == nil)
        #expect(ids(wm, "Scratch") == "2")
        #expect(wm.run("workspace next --wrap-around") == nil)
        #expect(wm.focusedWorkspace == "1", "Scratch is left out of next/prev")
    }

    @Test func scratchpadNewOpensAWindowForIt() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        term.newWindow = 3
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Shell --window-id 2") == nil)
        #expect(wm.run("focus --window-id 1") == nil)
        term.onPress = {
            term.focused = 2
            system.frontmost = 11
            system.send(.activated(11))
            term.send(.focusChanged)
        }

        // Its ⌘N menu item opens window 3: the scratchpad, shown.
        #expect(wm.run("scratchpad --new term") == nil)
        #expect(term.newWindowPresses == 1)
        #expect(term.frames[3] == Self.scratchpadFrame && other.frames[1] == Self.full)
        #expect(wm.focusedWorkspace == "1", "the app coming forward doesn't show Shell")
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output == "3")

        // Another one takes its place; the first goes away, to the fallback workspace.
        term.newWindow = 4
        #expect(wm.run("scratchpad --new term") == nil)
        #expect(term.frames[4] == Self.scratchpadFrame && ids(wm, "Scratch") == "3")

        // A dialog its ⌘N opens first (a template chooser) isn't taken: the window after it is.
        term.newWindow = 6
        term.onPress = { term.create(5, frame: CGRect(x: 10, y: 10, width: 300, height: 200), floating: true) }
        #expect(wm.run("scratchpad --new term") == nil)
        #expect(term.frames[6] == Self.scratchpadFrame && term.frames[5] == CGRect(x: 10, y: 10, width: 300, height: 200))
        #expect(Set(ids(wm, "Scratch").split(separator: "\n")) == ["3", "4"])
        term.destroy(5)

        // The same key without --new puts it away.
        #expect(wm.run("scratchpad term") == nil)
        #expect(Set(ids(wm, "Scratch").split(separator: "\n")) == ["3", "4", "6"] && ids(wm, "Shell") == "2")
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output == "1")
    }

    @Test func scratchpadNewWithoutANewWindowItemTakesAWindowOfTheApp() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Shell --window-id 2") == nil)
        #expect(wm.run("focus --window-id 1") == nil)
        #expect(wm.run("scratchpad --new term") == nil)
        #expect(term.frames[2] == Self.scratchpadFrame)
        #expect(wm.run("scratchpad --new term") == nil, "shown and focused: put away")
        #expect(ids(wm, "Shell") == "2")

        // Not running: launched, as without --new.
        #expect(wm.run("scratchpad --new another") == nil)
        #expect(system.opened == ["another"])
    }

    @Test func tilingOrMovingAScratchpadMakesItOrdinary() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2), window(3)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Shell --window-id 3") == nil)
        #expect(wm.run("focus --window-id 1") == nil)

        // Tiled: it stays in the workspace, and the key takes the app's other window.
        #expect(wm.run("scratchpad term") == nil)
        let first = Int(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output)!
        #expect(wm.run("layout tiling") == nil)
        #expect(wm.run("scratchpad term") == nil)
        let second = Int(wm.run(words: ["list-windows", "--focused", "--format", "%{window-id}"]).output)!
        #expect(second != first)
        #expect(wm.run("scratchpad term") == nil, "put away")
        #expect(term.frames[WindowID(second)]?.origin == Self.corner)
        #expect(wm.run(words: ["list-windows", "--workspace", "1", "--format", "%{window-id} %{window-layout}"]).output == "1 tiling\n\(first) tiling")

        // Moved to another workspace: it stays there too.
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.run("move-node-to-workspace Shell") == nil)
        #expect(wm.run("scratchpad term") == nil, "both are ordinary now: the most recent one is taken again")
        #expect(wm.run(words: ["list-windows", "--focused", "--format", "%{window-layout}"]).output == "floating")
    }

    @Test func theScratchpadSurvivesARestart() {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let first = started(system)
        #expect(first.run("move-node-to-workspace Shell --window-id 2") == nil)
        #expect(first.run("focus --window-id 1") == nil)
        #expect(first.run("scratchpad term") == nil)
        first.stop()
        #expect(term.frames[2] == Self.scratchpadFrame)

        // Started again: still shown, and the key still knows where it goes back to.
        let wm = started(system)
        defer { wm.stop() }
        #expect(term.frames[2] == Self.scratchpadFrame && other.frames[1] == Self.full)
        #expect(wm.run("focus --window-id 2") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(term.frames[2]?.origin == Self.corner)
        #expect(wm.run(words: ["list-windows", "--workspace", "Shell", "--format", "%{window-id} %{window-layout}"]).output == "2 tiling")
    }

    @Test func aScratchpadPutAwayIsAnOrdinaryWindowOfItsWorkspace() async throws {
        let other = FakeApp(pid: 10, bundleID: "other", windows: [window(1)])
        let term = FakeApp(pid: 11, bundleID: "term", windows: [window(2)])
        let system = FakeSystem(screens: [Self.main], apps: [other, term])
        let wm = started(system)
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Shell --window-id 2") == nil)
        #expect(wm.run("focus --window-id 1") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(wm.run("scratchpad term") == nil)
        #expect(other.frames[1] == Self.full && term.frames[2]?.origin == Self.corner)

        // ⌘-Tab to the app (past the activations the key itself causes): its workspace
        // shows, the window tiled there as before.
        try await Task.sleep(for: .milliseconds(1100))
        term.focused = 2
        system.frontmost = 11
        system.send(.activated(11))
        #expect(wm.focusedWorkspace == "Shell")
        #expect(term.frames[2] == Self.full)

        // Closed: nothing is left of it.
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

    @Test func workspacesListTheirApps() {
        let a = FakeApp(pid: 10, bundleID: "a", windows: [window(1), window(2)])
        let b = FakeApp(pid: 11, bundleID: "b", windows: [window(3)])
        let wm = started(FakeSystem(screens: [Self.main, Self.dell], apps: [a, b]))
        defer { wm.stop() }
        #expect(wm.run("move-node-to-workspace Music --window-id 3") == nil)
        #expect(wm.run("move-node-to-workspace Cad --window-id 2") == nil)
        let rows = wm.workspaceWindows.map { "\($0.focused ? "*" : "")\($0.name): \($0.windows.map { "\($0.app)/\($0.title)" }.joined(separator: " "))" }
        // Numbers first; the DELL's empty shown workspace too.
        #expect(rows == ["*1: a/window 1", "2: ", "Cad: a/window 2", "Music: b/window 3"])
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
