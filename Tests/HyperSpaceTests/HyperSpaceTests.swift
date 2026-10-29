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
