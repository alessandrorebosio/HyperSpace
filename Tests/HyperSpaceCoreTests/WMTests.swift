import CoreGraphics
import Foundation
@testable import HyperSpaceCore
import Testing

struct WMTests {
    private static let screen = WMMonitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                          visible: CGRect(x: 0, y: 0, width: 1000, height: 600))

    /// A model with windows 1...n tiled on workspace 1, window n focused.
    private func model(_ count: WindowID, settings: WMSettings = WMSettings()) -> WMModel {
        let model = WMModel(monitors: [WMTests.screen], settings: settings)
        for id in 1...count {
            model.add(WMWindowInfo(id: id, floating: false))
            model.nativeFocus(id)
        }
        return model
    }

    private func run(_ model: WMModel, _ command: String) throws {
        _ = try model.run(WMCommand(parsing: command))
    }

    /// The tree as text: h[1 v[2 3]].
    private func tree(_ node: WMNode) -> String {
        if let window = node.window { return "\(window)" }
        let kind = (node.orientation == .horizontal ? "h" : "v") + (node.layout == .accordion ? "a" : "")
        return "\(kind)[\(node.children.map(tree).joined(separator: " "))]"
    }

    @Test func newWindowsTileNextToTheFocusedOne() {
        let m = model(3)
        #expect(tree(m.focusedWorkspace.root) == "h[1 2 3]")
        #expect(m.layout().tiled == [
            1: CGRect(x: 0, y: 0, width: 333, height: 600),
            2: CGRect(x: 333, y: 0, width: 334, height: 600),
            3: CGRect(x: 667, y: 0, width: 333, height: 600),
        ])
    }

    @Test func gapsAndWeights() throws {
        var settings = WMSettings()
        settings.gaps.innerHorizontal = GapValue(10)
        for side in [\GapsConfig.outerLeft, \.outerRight, \.outerTop, \.outerBottom] { settings.gaps[keyPath: side] = GapValue(20) }
        let m = model(2, settings: settings)
        #expect(m.layout().tiled[1] == CGRect(x: 20, y: 20, width: 475, height: 560))
        #expect(m.layout().tiled[2] == CGRect(x: 505, y: 20, width: 475, height: 560))
        try run(m, "resize smart +100")
        #expect(m.layout().tiled[2]?.width == 575)
        try run(m, "balance-sizes")
        #expect(m.layout().tiled[2]?.width == 475)
    }

    @Test func moveSwapsSiblingsAndMakesContainers() throws {
        let m = model(3)
        try run(m, "move left")
        #expect(tree(m.focusedWorkspace.root) == "h[1 3 2]")
        try run(m, "move down")
        #expect(tree(m.focusedWorkspace.root) == "v[h[1 2] 3]", "past the edge: a new root across")
        try run(m, "move up")
        #expect(tree(m.focusedWorkspace.root) == "h[1 2 3]", "into the container, after its most recent window")
    }

    @Test func moveIntoASiblingContainer() throws {
        let m = model(3)
        try run(m, "join-with left") // 3 joins 2
        #expect(tree(m.focusedWorkspace.root) == "h[1 v[2 3]]")
        m.nativeFocus(1)
        try run(m, "move right")
        #expect(tree(m.focusedWorkspace.root) == "v[2 3 1]", "entered the container next to its recent window, then normalized")
    }

    @Test func focusFollowsTheTree() throws {
        let m = model(3)
        try run(m, "join-with left")
        #expect(tree(m.focusedWorkspace.root) == "h[1 v[2 3]]")
        try run(m, "focus up")
        #expect(m.focused == 2)
        try run(m, "focus left")
        #expect(m.focused == 1)
        try run(m, "focus right")
        #expect(m.focused == 2, "back into the container's most recent window")
        try run(m, "focus right")
        #expect(m.focused == 2, "edge: stays")
    }

    @Test func commandsWorkWithoutAReportedFocus() throws {
        let m = WMModel(monitors: [WMTests.screen])
        for id: WindowID in 1...2 { m.add(WMWindowInfo(id: id, floating: false)) }
        #expect(m.focused == nil, "the app never reported its focused window")
        try run(m, "move right")
        #expect(tree(m.focusedWorkspace.root) == "h[2 1]", "acted on the workspace's first window")
    }

    @Test func layoutCommands() throws {
        let m = model(3)
        try run(m, "layout tiles accordion")
        #expect(tree(m.focusedWorkspace.root) == "ha[1 2 3]")
        try run(m, "layout tiles accordion")
        #expect(tree(m.focusedWorkspace.root) == "h[1 2 3]")
        try run(m, "layout vertical")
        #expect(tree(m.focusedWorkspace.root) == "v[1 2 3]")
        try run(m, "layout floating")
        #expect(tree(m.focusedWorkspace.root) == "v[1 2]")
        #expect(m.focusedWorkspace.floating == [3])
        #expect(m.layout().floating[3] == 1)
        try run(m, "layout floating tiling")
        #expect(m.focusedWorkspace.floating.isEmpty)
    }

    @Test func accordionShowsPaddingAroundTheRecentWindow() throws {
        var settings = WMSettings()
        settings.accordionPadding = 30
        let m = model(3, settings: settings)
        m.nativeFocus(2)
        try run(m, "layout accordion")
        let frames = m.layout().tiled
        // AeroSpace's padding: the recent window is inset on both sides, the others peek out.
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 970, height: 600))
        #expect(frames[2] == CGRect(x: 30, y: 0, width: 940, height: 600))
        #expect(frames[3] == CGRect(x: 30, y: 0, width: 970, height: 600))
    }

    @Test func workspacesHideAndShowWindows() throws {
        let m = model(2)
        try run(m, "move-node-to-workspace 2")
        #expect(m.focusedWorkspace.name == "1")
        #expect(m.focused == 1)
        #expect(m.layout().hidden[2] == 1)
        try run(m, "workspace 2")
        #expect(m.layout().tiled[2] == CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(m.layout().hidden[1] == 1)
        #expect(m.focused == 2)
        try run(m, "workspace-back-and-forth")
        #expect(m.focusedWorkspace.name == "1")
        try run(m, "workspace next")
        #expect(m.focusedWorkspace.name == "2")
    }

    @Test func nativeFocusShowsItsWorkspace() throws {
        let m = model(2)
        try run(m, "move-node-to-workspace 5")
        #expect(m.nativeFocus(2), "⌘-Tab to a hidden window shows its workspace")
        #expect(m.focusedWorkspace.name == "5")
    }

    @Test func emptyHiddenWorkspacesAreDropped() throws {
        let m = model(1)
        try run(m, "workspace 3")
        try run(m, "workspace 1")
        #expect(m.workspaces["3"] == nil)
    }

    @Test func removingAWindowRefocuses() {
        let m = model(3)
        m.remove(3)
        #expect(m.focused == 2)
        #expect(tree(m.focusedWorkspace.root) == "h[1 2]")
    }

    @Test func commandsActOnAnExplicitWindow() throws {
        let m = model(3)
        _ = try m.run(WMCommand(parsing: "move-node-to-workspace 9"), window: 1)
        #expect(m.workspace(of: 1)?.name == "9", "the callback's window, not the focused one")
        #expect(m.focused == 3)
        #expect(throws: InvalidConfig.self) { try m.run(WMCommand(parsing: "close"), window: 42) }
    }

    @Test func fullscreenCoversTheWorkspace() throws {
        let m = model(2)
        try run(m, "fullscreen")
        #expect(m.layout().tiled[2] == CGRect(x: 0, y: 0, width: 1000, height: 600))
        try run(m, "fullscreen")
        #expect(m.layout().tiled[2]?.width == 500)
    }

    @Test func twoMonitors() throws {
        let right = WMMonitor(id: 2, frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                              visible: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let m = WMModel(monitors: [WMTests.screen, right])
        #expect(m.visible == [1: "1", 2: "2"])
        m.add(WMWindowInfo(id: 1, floating: false), monitor: 2)
        #expect(m.workspace(of: 1)?.name == "2")
        try run(m, "focus-monitor right")
        #expect(m.focusedMonitor == 2)
        #expect(m.focused == 1)
        try run(m, "move-node-to-monitor left")
        #expect(m.workspace(of: 1)?.name == "1")
        try run(m, "workspace 2")
        #expect(m.focusedMonitor == 2, "a workspace shown elsewhere: go to its monitor")
    }

    @Test func displaysLeavingAndComingBack() throws {
        let main = WMMonitor(id: 1, name: "Built-in", isMain: true, frame: WMTests.screen.frame, visible: WMTests.screen.visible)
        let dell = WMMonitor(id: 2, name: "DELL", frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                             visible: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let m = WMModel(monitors: [main, dell])
        m.add(WMWindowInfo(id: 1, floating: false), monitor: 1)
        m.add(WMWindowInfo(id: 2, floating: false), monitor: 2)
        m.nativeFocus(2)
        m.setMonitors([main])
        #expect(m.visible == [1: "1"])
        #expect(m.layout().hidden[2] == 1, "parked on a display that is there")
        #expect(m.focused == 1, "focus follows what is still shown")
        m.setMonitors([main, dell])
        #expect(m.visible == [1: "1", 2: "2"], "the display shows its workspace again")
        // Back from sleep under another id: still the same display.
        let renamed = WMMonitor(id: 7, name: "DELL", frame: dell.frame, visible: dell.visible)
        m.setMonitors([main, renamed])
        #expect(m.visible == [1: "1", 7: "2"])
        #expect(m.layout().tiled[2] != nil)
    }

    @Test func forcedWorkspacesMoveToTheirDisplay() throws {
        let main = WMMonitor(id: 1, name: "Built-in", isMain: true, frame: WMTests.screen.frame, visible: WMTests.screen.visible)
        let dell = WMMonitor(id: 2, name: "DELL", frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                             visible: CGRect(x: 1000, y: 0, width: 800, height: 600))
        var config = WMConfig()
        config.workspaceToMonitorForceAssignment = ["Develop": ["dell"]]
        let m = WMModel(monitors: [main], settings: try WMSettings(config))
        m.add(WMWindowInfo(id: 1, floating: false))
        try run(m, "move-node-to-workspace Develop --focus-follows-window")
        #expect(m.visible == [1: "Develop"], "its display isn't there: shown on main")
        m.setMonitors([main, dell])
        #expect(m.visible[2] == "Develop" && m.visible[1] != "Develop")
        #expect(m.layout().tiled[1]?.minX == 1000)
    }

    @Test func commandsParseLikeAeroSpace() throws {
        #expect(try WMCommand(parsing: "move-node-to-workspace 3 --focus-follows-window")
            == .moveNodeToWorkspace(.named("3"), focusFollows: true, wrapAround: false, window: nil, failIfNoop: false))
        #expect(try WMCommand(parsing: "resize width -50") == .resize(.width, .add(-50), window: nil))
        #expect(try WMCommand(parsing: "move-workspace-to-monitor --wrap-around next") == .moveWorkspaceToMonitor(.next, wrapAround: true, workspace: nil))
        #expect(try WMCommand(parsing: "focus-monitor main dell") == .focusMonitor(.patterns(["main", "dell"]), wrapAround: false))
        #expect(try WMCommand(parsing: "test %{app-bundle-id} = com.apple.Terminal") == .test("%{app-bundle-id}", .equals, "com.apple.Terminal", negate: false))
        #expect(try WMCommand(parsing: "list-windows --workspace focused --format '%{app-name} %{window-title}'")
            == .list(.init(kind: .windows, filters: ["--workspace": ["focused"]], format: "%{app-name} %{window-title}")))
        #expect(throws: InvalidConfig.self) { try WMCommand(parsing: "focus sideways") }
        #expect(throws: InvalidConfig.self) { try WMCommand(parsing: "teleport") }
        #expect(throws: InvalidConfig.self) { try WMCommand(parsing: "workspace 1 --bogus") }
    }

    @Test func shellSyntax() throws {
        let script = try WMScript(parsing: "true && workspace 1 || workspace 2; mode main")
        #expect(script == .sequence([
            .or(.and(.command(.result(true)), .command(.workspace(.named("1"), autoBackAndForth: false, wrapAround: false, failIfNoop: false))),
                .command(.workspace(.named("2"), autoBackAndForth: false, wrapAround: false, failIfNoop: false))),
            .command(.mode("main")),
        ]))
        // exec-and-forget passes the rest to bash untouched, quotes and ';' included.
        #expect(try WMScript(parsing: "exec-and-forget osascript -e 'tell app \"Terminal\" to activate'; echo x")
            == .command(.exec("osascript -e 'tell app \"Terminal\" to activate'; echo x")))
        // || runs the right side only when the left one fails.
        var ran: [String] = []
        try WMScript(parsing: "false || echo a; true || echo b; (false && echo c) || echo d").run { command in
            if case let .echo(text) = command { ran.append(text) }
            if case let .result(value) = command { return value }
            return true
        }
        #expect(ran == ["a", "d"])
        #expect(throws: InvalidConfig.self) { try WMScript(parsing: "list-workspaces --all | workspace --stdin next") }
    }

    @Test func workspacesFollowTheirAssignedMonitor() throws {
        let right = WMMonitor(id: 2, name: "DELL U2720Q", frame: CGRect(x: 1000, y: 0, width: 800, height: 600),
                              visible: CGRect(x: 1000, y: 0, width: 800, height: 600))
        let main = WMMonitor(id: 1, name: "Built-in Retina Display", isMain: true, frame: WMTests.screen.frame, visible: WMTests.screen.visible)
        var config = WMConfig()
        config.persistentWorkspaces = ["Develop"]
        config.workspaceToMonitorForceAssignment = ["Develop": ["dell"]]
        let m = WMModel(monitors: [main, right], settings: try WMSettings(config))
        #expect(m.visible[2] == "Develop", "an assigned workspace shows on its monitor")
        try run(m, "workspace 5")
        #expect(m.visible[1] == "5", "unassigned workspaces open on the main monitor")
        try run(m, "focus-monitor right")
        try run(m, "workspace 6")
        #expect(m.visible[1] == "6" && m.visible[2] == "Develop", "even from another monitor, as in AeroSpace")
        try run(m, "workspace 1")
        #expect(m.workspaces["Develop"] != nil, "persistent workspaces stay even when empty")
    }

    @Test func swapSummonAndFocusBackAndForth() throws {
        let m = model(3)
        try run(m, "swap left")
        #expect(tree(m.focusedWorkspace.root) == "h[1 3 2]")
        try run(m, "focus left")
        #expect(m.focused == 1)
        try run(m, "focus-back-and-forth")
        #expect(m.focused == 3)
        try run(m, "move-node-to-workspace 4")
        try run(m, "summon-workspace 4")
        #expect(m.focusedWorkspace.name == "4")
    }

    @Test func focusBoundaries() throws {
        let m = model(3)
        #expect(try m.run(WMCommand(parsing: "focus right --boundaries-action fail")).ok == false)
        try run(m, "focus right --boundaries-action wrap-around-the-workspace")
        #expect(m.focused == 1)
        try run(m, "focus dfs-prev --wrap-around")
        #expect(m.focused == 3)
    }

    @Test func gapsPerSideAndMonitor() throws {
        var config = WMConfig()
        config.gaps.innerHorizontal = GapValue(10)
        config.gaps.outerLeft = GapValue(5)
        var top = GapValue(24)
        top.perMonitor = [("built-in", 40)]
        config.gaps.outerTop = top
        let monitor = WMMonitor(id: 1, name: "Built-in Retina Display", isMain: true, frame: WMTests.screen.frame, visible: WMTests.screen.visible)
        let m = WMModel(monitors: [monitor], settings: try WMSettings(config))
        for id: WindowID in 1...2 {
            m.add(WMWindowInfo(id: id, floating: false))
            m.nativeFocus(id)
        }
        #expect(m.layout().tiled[1] == CGRect(x: 5, y: 40, width: 493, height: 560))
        #expect(m.layout().tiled[2] == CGRect(x: 508, y: 40, width: 492, height: 560))
    }

    @Test func keyNotation() throws {
        #expect(try WMKeys.combo("ctrl-alt-shift-leftSquareBracket", path: "")
            == Combo(key: KeyNames.key("bracket.open")!, modifiers: [.control, .option, .shift]))
        #expect(try WMKeys.combo("alt-keypad1", path: "").key == KeyNames.key("keypad.1"))
    }

    @Test func capsLockHoldTriggersHotkeys() throws {
        var config = Config()
        config.keyboard = try ConfigLoader.parse(KeyboardConfig.self, "[capslock]\nhold = \"shift-ctrl-opt\"").get()
        config.wm = try ConfigLoader.parse(WMConfig.self, "[mode.main.binding]\nctrl-alt-shift-h = 'focus left'\n[mode.service.binding]\nesc = 'mode main'").get()
        let plan = try InputPlan(config)
        let tables = plan.tables(forApp: nil)
        var e = KeyEngine()
        _ = e.handle(code: Layer.capsLockTrigger, down: true, isRepeat: false, now: 0, tables: tables)
        #expect(e.handle(code: 4, down: true, isRepeat: false, now: 1, tables: tables) == .emit(.wm("focus left")))
        #expect(e.handle(code: 4, down: false, isRepeat: false, now: 2, tables: tables) == .drop)
        _ = e.handle(code: Layer.capsLockTrigger, down: false, isRepeat: false, now: 3, tables: tables)
        #expect(e.handle(code: 4, down: true, isRepeat: false, modifiers: .option, now: 4, tables: tables) == .pass)
        // In the service mode only its own bindings are active.
        let service = plan.tables(forApp: nil, mode: "service")
        #expect(e.handle(code: 53, down: true, isRepeat: false, now: 5, tables: service) == .emit(.wm("mode main")))
    }

    @Test func savedLayoutComesBack() throws {
        let m = model(4)
        try run(m, "move down")
        try run(m, "resize smart +100")
        try run(m, "focus up")
        try run(m, "move-node-to-workspace 2")
        try run(m, "layout floating tiling")
        let names = Dictionary(uniqueKeysWithValues: (WindowID(1)...4).map { ($0, WMSnapshot.Identity(app: "a", title: "\($0)")) })
        let snapshot = try JSONDecoder().decode(WMSnapshot.self, from: JSONEncoder().encode(m.snapshot { names[$0]! }))

        // A restart: the same windows come back in another order, all on the focused workspace.
        let fresh = WMModel(monitors: [WMTests.screen])
        for id: WindowID in [4, 3, 2, 1] { fresh.add(WMWindowInfo(id: id, floating: false)) }
        fresh.restore(snapshot, map: snapshot.match(names))
        #expect(tree(fresh.workspace("1").root) == tree(m.workspace("1").root))
        #expect(fresh.workspace("1").floating == m.workspace("1").floating)
        #expect(fresh.windows == m.windows)
        #expect((1...4).allSatisfy { fresh.workspace(of: $0)?.name == m.workspace(of: $0)?.name })
        #expect(m.workspace("2").windows.count == 1)
        #expect(fresh.layout() == m.layout(), "weights and visible workspace included")

        // A window the layout didn't know stays, after the restored ones.
        let more = WMModel(monitors: [WMTests.screen])
        for id: WindowID in [5, 1, 2, 3, 4] { more.add(WMWindowInfo(id: id, floating: false)) }
        more.restore(snapshot, map: snapshot.match(names))
        #expect(tree(more.workspace("1").root).hasSuffix(" 5]"))
    }

    @Test func savedWindowsMatchByIdThenAppAndTitle() {
        let saved = WMSnapshot(workspaces: [], visible: [:], focusedWorkspace: "1", windows: [
            1: .init(app: "a", title: "x"), 2: .init(app: "b", title: "y"), 3: .init(app: "b", title: "y"),
        ])
        // Window 1 is still there; app b restarted: its windows have new ids, matched by title once each.
        let map = saved.match([1: .init(app: "a", title: "changed"), 10: .init(app: "b", title: "y"), 11: .init(app: "b", title: "z")])
        #expect(map == [1: 1, 2: 10])
    }
}
