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

    /// Binding the same shortcut twice keeps one action: the last (no orphan left in the list).
    @Test func lastBindingWins() throws {
        let config = try config(#"""
        {"keyboard":{"bindings":[{"keys":"hyper+h","action":"focus left"},{"keys":"hyper+h","action":"focus right"}]},
         "mouse":{"buttons":[{"button":3,"action":"navigate back"},{"button":3,"action":"navigate forward"}]}}
        """#)
        let combo = try KeyCombo.parse("hyper+h")
        let key = config.tap.keyTable[TapConfig.slot(Int(combo.keyCode), combo.modifiers)]
        #expect(config.tap.actions[Int(key)] == .focus(.right))
        let button = config.tap.buttonTable[TapConfig.slot(3, [])]
        #expect(config.tap.actions[Int(button)] == .navigate(back: false))
        #expect(config.tap.actions.count == 2)
    }

    @Test func spacingIsClamped() throws {
        let tiling = try config(#"{"tiling":{"gap":500,"padding":-3}}"#).tiling
        #expect(tiling.gap == 64)
        #expect(tiling.padding == 0)
        #expect(try config("{}").tiling.gap == TilingConfig().gap)
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
        for item in TilingModel.shortcutActions { #expect((try? Action.parse(item.action)) != nil, "\(item.action)") }
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

@Suite struct ColumnAccordionTests {
    /// Two windows side by side → one accordion → moving one out puts them side by side again.
    @Test func toggleAndMoveOut() {
        var layout = ColumnLayout(columns: [[1], [2]])
        let on = layout.toggleAccordion(around: 2)
        #expect(on)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        #expect(layout.columns[0].accordion && layout.columns[0].front == 2)
        let frames = layout.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 600), gap: 10, peek: 30) { _ in 1 }
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 970, height: 600))
        #expect(frames[2] == CGRect(x: 30, y: 0, width: 970, height: 600))
        layout.move(2, .right)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(!layout.columns[0].accordion)
    }

    @Test func toggleOffAndNewWindows() {
        var layout = ColumnLayout(columns: [[1], [2, 3]])
        layout.toggleAccordion(around: 1)
        // A new window opened while the accordion has the focus joins it.
        layout.sync(with: [1, 2, 3, 4], focused: 1)
        #expect(layout.columns.map(\.windows) == [[1, 4, 2, 3]])
        #expect(layout.accordionNeighbor(of: 4, 1) == 2)
        let still = layout.toggleAccordion(around: 4)
        #expect(!still)
        #expect(layout.columns.map(\.windows) == [[1], [4], [2], [3]])
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

    /// Same-size windows; the ones before the focused one on the left edge, after it on the right.
    @Test func accordion() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let middle = Layout.frames(.accordion, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: 1, peek: 30)
        #expect(middle == [CGRect(x: 0, y: 0, width: 940, height: 600),
                           CGRect(x: 30, y: 0, width: 940, height: 600),
                           CGRect(x: 60, y: 0, width: 940, height: 600)])
        let first = Layout.frames(.accordion, weights: [1, 1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30)
        #expect(first == [CGRect(x: 0, y: 0, width: 970, height: 600), CGRect(x: 30, y: 0, width: 970, height: 600)])
        #expect(Layout.frames(.accordion, weights: [1], in: area, gap: 10, ratio: 0.5, focused: 0, peek: 30) == [area])
    }

    /// Moving to another display keeps position and size as shares of the visible area.
    @Test func relocate() {
        let small = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
                               visible: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let large = ScreenInfo(id: 2, frame: CGRect(x: 1000, y: -200, width: 2000, height: 1225),
                               visible: CGRect(x: 1000, y: -175, width: 2000, height: 1200))
        #expect(small.relocate(CGRect(x: 250, y: 150, width: 500, height: 300), to: large)
                == CGRect(x: 1500, y: 125, width: 1000, height: 600))
        // Too big for the destination: shrunk and kept inside it.
        #expect(large.relocate(CGRect(x: 1000, y: -175, width: 2000, height: 1200), to: small) == small.visible)
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

    @Test func windowMissingTheSizeStaysCentered() {
        let frame = CGRect(x: 294, y: 172, width: 882, height: 646)
        // A terminal that only takes whole character cells.
        let fitted = WindowManager.centered(CGSize(width: 875, height: 640), in: frame)
        #expect(fitted == CGRect(x: 298, y: 175, width: 875, height: 640))
        #expect(WindowManager.centered(frame.size, in: frame) == frame)
    }

    @Test func actionsAndSize() throws {
        let config = try HyperSpaceTests.config(#"""
        {"keyboard":{"bindings":[{"keys":"meh+x","action":"scratchpad com.anthropic.claudefordesktop"},
                                 {"keys":"hyper+x","action":"move-to-scratchpad"},{"keys":"meh+z","action":"scratchpad"},
                                 {"keys":"hyper+c","action":"move-to-scratchpad com.anthropic.claudefordesktop"}]},
         "tiling":{"scratchpad":{"width":0.5,"height":2}}}
        """#)
        #expect(try action(config, "meh+x") == "scratchpad(Optional(\"com.anthropic.claudefordesktop\"))")
        #expect(try action(config, "hyper+x") == "moveToScratchpad(nil)")
        #expect(try action(config, "meh+z") == "scratchpad(nil)")
        #expect(try action(config, "hyper+c") == "moveToScratchpad(Optional(\"com.anthropic.claudefordesktop\"))")
        #expect(config.tiling.scratchpadSize == CGSize(width: 0.5, height: 1))
    }
}

@Suite struct KeyboardTests {
    /// `print_screen` shares its key code with F13: F13 cannot be a carrier then.
    @Test func carriersAvoidKeysSharingAKeyCode() {
        #expect(throws: ConfigError.self) {
            try config(#"""
            { "keyboard": { "remap": [ { "from": "print_screen", "to": "escape" }, { "from": "caps_lock", "to": "meh" } ] },
              "tiling": { "workspaces": [
                { "switch": "f20" }, { "switch": "f19" }, { "switch": "f18" }, { "switch": "f17" },
                { "switch": "f16" }, { "switch": "f15" }, { "switch": "f14" } ] } }
            """#)
        }
    }

    @Test func modifierKeysAreFoundByName() {
        #expect(Modifiers.modifierKey("right_command") == .cmd)
        #expect(Modifiers.modifierKey("left_alt") == .alt)
        #expect(Modifiers.modifierKey("caps_lock") == nil)
        #expect(Modifiers.modifierKey("a") == nil)
    }

    @Test func carriersFollowTheLayout() throws {
        let config = try config(#"{ "keyboard": { "remap": [ { "from": "right_command", "to": "cmd+-" } ] } }"#)
        let minus = try KeyCombo.parse("-").keyCode
        #expect(config.tap.carriers.map(\.keyCode) == [minus])
        let translated = config.tap.translated { $0 == minus ? 0x2C : $0 }
        #expect(translated.carriers.map(\.keyCode) == [0x2C])
        #expect(translated != config.tap)
        #expect(translated.translated { $0 } == translated)
    }
}
