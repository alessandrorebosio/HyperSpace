import CoreGraphics
@testable import HyperSpaceCore
import Testing

struct WMTests {
    private static let screen = WMMonitor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                                          visible: CGRect(x: 0, y: 0, width: 1000, height: 600))

    /// A model with windows 1...n tiled on workspace 1, window n focused.
    private func model(_ count: WindowID, settings: WMSettings = WMSettings()) -> WMModel {
        let model = WMModel(monitors: [WMTests.screen], settings: settings)
        for id in 1...count {
            model.add(WMWindowInfo(id: id, pid: 1, bundleID: "app", floating: false))
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
        settings.innerGap = 10
        settings.outerGap = 20
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
        for id: WindowID in 1...2 { m.add(WMWindowInfo(id: id, pid: 1, bundleID: nil, floating: false)) }
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

    @Test func rulesPickWorkspaceAndFloating() throws {
        var config = WMConfig()
        config.rule = [WMRule(app: "com.apple.finder", layout: "floating", workspace: "9")]
        let m = WMModel(monitors: [WMTests.screen], settings: try WMSettings(config))
        m.add(WMWindowInfo(id: 7, pid: 1, bundleID: "com.apple.finder", floating: false))
        #expect(m.workspace("9").floating == [7])
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
        m.add(WMWindowInfo(id: 1, pid: 1, bundleID: nil, floating: false), monitor: 2)
        #expect(m.workspace(of: 1)?.name == "2")
        try run(m, "focus-monitor right")
        #expect(m.focusedMonitor == 2)
        #expect(m.focused == 1)
        try run(m, "move-node-to-monitor left")
        #expect(m.workspace(of: 1)?.name == "1")
        try run(m, "workspace 2")
        #expect(m.focusedMonitor == 2, "a workspace shown elsewhere: go to its monitor")
    }

    @Test func commandsParseLikeAeroSpace() throws {
        #expect(try WMCommand(parsing: "move-node-to-workspace 3 --focus-follows-window") == .moveNodeToWorkspace(.named("3"), focusFollows: true))
        #expect(try WMCommand(parsing: "resize width -50") == .resize(.width, .add(-50)))
        #expect(try WMCommand(parsing: "exec-and-forget open -a Terminal") == .exec("open -a Terminal"))
        #expect(throws: InvalidConfig.self) { try WMCommand(parsing: "focus sideways") }
        #expect(throws: InvalidConfig.self) { try WMCommand(parsing: "teleport") }
    }

    @Test func bindingsBecomeHotkeys() throws {
        var config = WMConfig()
        config.enabled = true
        config.bindings = ["alt-h": ["focus left"], "shift-ctrl-opt-1": ["workspace 1", "layout tiles"]]
        let hotkeys = try Hotkeys.compile(config)
        #expect(hotkeys[Hotkeys.index(code: 4, modifiers: .option)] == .wm("focus left"))
        #expect(hotkeys[Hotkeys.index(code: 18, modifiers: [.shift, .control, .option])]
            == .sequence([.wm("workspace 1"), .wm("layout tiles")]))
        config.bindings = ["alt-h": ["focus nowhere"]]
        #expect(throws: InvalidConfig.self) { try Hotkeys.compile(config) }
    }

    @Test func capsLockHoldTriggersHotkeys() throws {
        var config = Config()
        config.keyboard = try ConfigLoader.parse(KeyboardConfig.self, "[capslock]\nhold = \"meh\"").get()
        config.wm = try ConfigLoader.parse(WMConfig.self, "enabled = true\n[bindings]\n\"meh-h\" = \"focus left\"").get()
        let tables = try InputPlan(config).tables(forApp: nil)
        var e = KeyEngine()
        _ = e.handle(code: Layer.capsLockTrigger, down: true, isRepeat: false, now: 0, tables: tables)
        #expect(e.handle(code: 4, down: true, isRepeat: false, now: 1, tables: tables) == .emit(.wm("focus left")))
        #expect(e.handle(code: 4, down: false, isRepeat: false, now: 2, tables: tables) == .drop)
        _ = e.handle(code: Layer.capsLockTrigger, down: false, isRepeat: false, now: 3, tables: tables)
        #expect(e.handle(code: 4, down: true, isRepeat: false, modifiers: .option, now: 4, tables: tables) == .pass)
    }
}
