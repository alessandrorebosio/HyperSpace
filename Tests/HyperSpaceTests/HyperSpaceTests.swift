import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

private func config(_ json: String) throws -> Config {
    try Config(JSONDecoder().decode(RawConfig.self, from: Data(json.utf8)))
}

/// The action bound to a shortcut, as text (Action is not Equatable).
private func action(_ config: Config, _ keys: String) throws -> String? {
    let combo = try KeyCombo.parse(keys)
    let index = config.tap.keyTable[TapConfig.slot(Int(combo.keyCode), combo.modifiers)]
    return index >= 0 ? "\(config.tap.actions[Int(index)])" : nil
}

@Suite struct ConfigTests {
    @Test func defaultConfigLoads() throws {
        let config = try config(DefaultConfig.json)
        #expect(config.tap.carriers.map(\.modifiers) == [.hyper])
        #expect(config.tap.suppressCapsLock)
        #expect(config.tiling.layout == .columns)
        #expect(config.tiling.mouseFollowsFocus)
        #expect(try !HyperSpaceTests.config(#"{"tiling":{"mouseFollowsFocus":false}}"#).tiling.mouseFollowsFocus)
    }

    @Test func workspaceShortcutsAndRules() throws {
        let config = try config(#"""
        { "tiling": {
            "workspaces": [ { "name": "1", "switch": "meh+1", "move": "hyper+1" },
                            { "name": "music", "switch": "meh+m" } ],
            "assign": [ { "app": "com.spotify.client", "workspace": "music" } ] } }
        """#)
        #expect(try action(config, "meh+1") == "workspace(0)")
        #expect(try action(config, "hyper+1") == "moveToWorkspace(0)")
        #expect(try action(config, "meh+m") == "workspace(1)")
        #expect(config.tiling.assignments["com.spotify.client"] == 1)
    }

    @Test func ruleForUnknownWorkspaceFails() {
        #expect(throws: ConfigError.self) {
            try config(#"{"tiling":{"workspaces":[{"name":"1"}],"assign":[{"app":"x","workspace":"nope"}]}}"#)
        }
    }

    /// Combination carriers (F13–F20) must avoid keys used by any shortcut, workspace ones included.
    @Test func carriersAvoidBoundKeys() throws {
        let config = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] },
          "tiling": { "workspaces": [ { "name": "a", "switch": "f20" }, { "name": "b", "switch": "f19" } ] } }
        """#)
        let carrier = config.tap.carrierTable.firstIndex { $0 >= 0 }
        #expect(carrier.flatMap { KeyCodes.name(forKeyCode: UInt16($0)) } == "f18")
    }

    @Test func sameCombinationSharesCarrier() throws {
        let config = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" },
                                   { "from": "right_option", "to": "ctrl+alt+shift" } ] } }
        """#)
        #expect(config.tap.carriers.count == 1)
        #expect(Set(config.remaps.map(\.to)).count == 1)
    }

    @Test func invalidCombinations() {
        #expect(throws: ConfigError.self) { try RemapTarget.parse("cmd+a+b") }
        #expect(throws: ConfigError.self) { try RemapTarget.parse("cmd+mute") }
        #expect(throws: ConfigError.self) { try KeyCombo.parse("hyper+volume_up") }
    }
}

@Suite struct ShortcutTextTests {
    @Test func text() {
        #expect(Modifiers.meh.text(key: nil) == "meh")
        #expect(Modifiers.meh.text(key: "1") == "meh+1")
        #expect(Modifiers.hyper.text(key: "h") == "hyper+h")
        #expect(Modifiers([.cmd]).text(key: "space") == "cmd+space")
        #expect(Modifiers([]).text(key: "escape") == "escape")
    }

    @Test func labels() {
        #expect(RemapTarget.label("meh+1") == "⌃⌥⇧ 1")
        #expect(RemapTarget.label("meh") == "Meh  ⌃⌥⇧")
        #expect(RemapTarget.label("cmd+space") == "⌘ Space")
        #expect(RemapTarget.label("escape") == "Escape")
    }

    @Test func presetsParse() {
        for item in MouseModel.presets.flatMap(\.items) { #expect((try? Action.parse(item.action)) != nil, "\(item.action)") }
        for item in TilingModel.shortcutActions.flatMap(\.items) { #expect((try? Action.parse(item.action)) != nil, "\(item.action)") }
        #expect(MouseModel.actionLabel("navigate back") == "Back")
        #expect("\((try? Action.parse("move-workspace-to-display"))!)" == "moveWorkspaceToNextDisplay")
        #expect(MouseModel.actionLabel("key cmd+left_bracket") == MouseModel.actionLabel("key cmd+["))
    }
}

@Suite struct ColumnLayoutTests {
    @Test func stackAndUnstack() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        layout.move(2, .down)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        layout.sync(with: [1, 2, 3])
        layout.move(3, .up)
        #expect(layout.columns.map(\.windows) == [[3, 1, 2]])
        layout.move(3, .down)
        #expect(layout.columns.map(\.windows) == [[1, 3, 2]])
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
        layout.move(2, .left)
        #expect(layout.columns.map(\.windows) == [[2], [1, 3]])
        layout.sync(with: [1, 2])
        #expect(layout.columns.map(\.windows) == [[2], [1]])
    }

    @Test func frames() {
        var layout = ColumnLayout()
        layout.sync(with: [1, 2])
        let side = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10) { _ in 1 }
        #expect(side[1] == CGRect(x: 0, y: 0, width: 500, height: 610))
        #expect(side[2] == CGRect(x: 510, y: 0, width: 500, height: 610))
        layout.move(2, .down)
        let stacked = layout.frames(in: CGRect(x: 0, y: 0, width: 1010, height: 610), gap: 10) { _ in 1 }
        #expect(stacked[2] == CGRect(x: 0, y: 310, width: 1010, height: 300))
    }
}

@Suite struct LayoutTests {
    @Test func weightedTall() {
        let frames = Layout.frames(.tall, weights: [1, 1, 2], in: CGRect(x: 0, y: 0, width: 1000, height: 610), gap: 10, ratio: 0.5)
        #expect(frames.map(\.height) == [610, 200, 400])
    }

    @Test func resizeWeight() {
        // Two equal columns of 500: +50 → 550 wide.
        let weight = WindowManager.weight(at: 0, of: [1, 1], growingBy: 50, length: 1010, gap: 10)
        #expect(abs(1000 * weight / (weight + 1) - 550) < 0.001)
    }

    /// Workspace n lives on display n; the others on the main display (index 0).
    @Test func workspaceHomes() {
        #expect((0..<6).map { WindowManager.homeIndex(of: $0, displays: 2) } == [0, 1, 0, 0, 0, 0])
        #expect((0..<4).map { WindowManager.homeIndex(of: $0, displays: 3) } == [0, 1, 2, 0])
        #expect(WindowManager.homeIndex(of: 1, displays: 1) == 0)
    }

    @Test func centered() {
        let screen = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                visible: CGRect(x: 0, y: 25, width: 800, height: 575))
        #expect(screen.centered(CGSize(width: 1000, height: 300)) == CGRect(x: 0, y: 162.5, width: 800, height: 300))
    }
}

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

@Suite struct FrameStepTests {
    typealias W = WindowManager
    let frame = CGRect(x: 100, y: 100, width: 800, height: 600)

    @Test func onlyWhatChanges() {
        #expect(W.frameSteps(from: frame, to: frame, sameDisplay: true) == [])
        #expect(W.frameSteps(from: frame, to: frame.offsetBy(dx: 50, dy: 0), sameDisplay: true) == [.position])
        #expect(W.frameSteps(from: frame, to: CGRect(x: 100, y: 100, width: 700, height: 600), sameDisplay: true) == [.size])
    }

    @Test func shrinkBeforeMovingGrowAfter() {
        #expect(W.frameSteps(from: frame, to: CGRect(x: 0, y: 0, width: 400, height: 300), sameDisplay: true) == [.size, .position])
        #expect(W.frameSteps(from: frame, to: CGRect(x: 0, y: 0, width: 1200, height: 600), sameDisplay: true) == [.position, .size])
    }

    @Test func acrossDisplaysOrUnknown() {
        #expect(W.frameSteps(from: frame, to: frame.offsetBy(dx: 2000, dy: 0), sameDisplay: false) == [.size, .position, .size])
        #expect(W.frameSteps(from: nil, to: frame, sameDisplay: true) == [.size, .position, .size])
    }
}

@Suite struct KeyboardLockTests {
    @Test func remaining() {
        let now = Date()
        #expect(KeyboardLock.remaining(until: now + 161, now: now) == "2:41")
        #expect(KeyboardLock.remaining(until: now + 0.2, now: now) == "0:01")
        #expect(KeyboardLock.remaining(until: now - 5, now: now) == "0:00")
        #expect(KeyboardLock.label(minutes: 0) == "Never")
    }
}

@Suite struct FloatingWindowTests {
    @Test func titleRules() throws {
        let config = try HyperSpaceTests.config(#"""
        {"tiling":{"floating":["com.apple.calculator"],
          "floatingWindows":[{"app":"com.autodesk.fusion360","title":"preferences"},{"title":"Picture-in-Picture"},{"title":""}]}}
        """#)
        let tiling = config.tiling
        #expect(tiling.floatingWindows.count == 2)
        #expect(tiling.floats(app: "com.apple.calculator", title: nil))
        #expect(tiling.floats(app: "com.autodesk.fusion360", title: "Preferences"))
        #expect(!tiling.floats(app: "com.autodesk.fusion360", title: "Untitled design"))
        #expect(!tiling.floats(app: "com.apple.Safari", title: "Preferences"))
        #expect(tiling.floats(app: "com.apple.Safari", title: "Picture-in-Picture"))
        #expect(!tiling.floats(app: "com.apple.Safari", title: nil))
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
                                   columns: ["3": [[0]]], displayed: ["1": 3], homeOverride: ["3": 2])
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

@Suite struct ScratchpadTests {
    @Test func frameIsCentered() {
        let visible = CGRect(x: 0, y: 33, width: 1470, height: 923)
        let frame = WindowManager.scratchpadFrame(in: visible, size: CGSize(width: 0.6, height: 0.7))
        #expect(frame.width == 882 && frame.height == 646)
        #expect(abs(frame.midX - visible.midX) <= 1 && abs(frame.midY - visible.midY) <= 1)
    }

    @Test func actionsAndSize() throws {
        let config = try HyperSpaceTests.config(#"""
        {"keyboard":{"bindings":[{"keys":"meh+x","action":"scratchpad com.anthropic.claudefordesktop"},
                                 {"keys":"hyper+x","action":"move-to-scratchpad"},{"keys":"meh+z","action":"scratchpad"}]},
         "tiling":{"scratchpad":{"width":0.5,"height":2}}}
        """#)
        #expect(try action(config, "meh+x") == "scratchpad(Optional(\"com.anthropic.claudefordesktop\"))")
        #expect(try action(config, "hyper+x") == "moveToScratchpad")
        #expect(try action(config, "meh+z") == "scratchpad(nil)")
        #expect(config.tiling.scratchpadSize == CGSize(width: 0.5, height: 1))
    }
}
