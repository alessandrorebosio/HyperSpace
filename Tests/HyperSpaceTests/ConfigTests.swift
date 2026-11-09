import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

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

    @Test func workspacePins() throws {
        let config = try config(#"""
        { "tiling": { "workspaces": [ { "name": "code", "display": "LG" }, { "name": "web", "display": " " },
                                      { "name": "chat", "display": "main" } ] } }
        """#)
        #expect(config.tiling.pins == [0: "LG", 2: "main"])
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

@Suite struct ConfigWriterTests {
    private let sample: [String: Any] = [
        "tiling": ["enabled": true, "gap": 8, "layout": "tall"] as [String: Any],
        "mouse": ["reverseScroll": false, "dragModifier": "cmd"] as [String: Any],
        "keyboard": [
            "remap": [["from": "capslock", "to": "hyper", "keyboard": "builtin"] as [String: Any]],
        ] as [String: Any],
        "bindings": [["keys": "cmd+a", "action": "say \"hi\" \\ a/b"] as [String: Any]],
    ]

    private func index(_ needle: String, in text: String) -> Int {
        text.range(of: needle)?.lowerBound.utf16Offset(in: text) ?? -1
    }

    @Test func roundTripsThroughJSON() throws {
        let text = ConfigWriter.text(for: sample)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: parsed).isEqual(to: sample))
    }

    @Test func topLevelKeysFollowTheKeyOrder() {
        let text = ConfigWriter.text(for: sample)
        let keyboard = index("\"keyboard\"", in: text)
        let mouse = index("\"mouse\"", in: text)
        let tiling = index("\"tiling\"", in: text)
        #expect(keyboard >= 0 && keyboard < mouse && mouse < tiling)
    }

    @Test func keyboardComesLastInsideARemapRule() {
        let text = ConfigWriter.text(for: ["keyboard": ["remap": [["keyboard": "builtin", "to": "hyper", "from": "capslock"]]]])
        #expect(text.contains("{ \"from\": \"capslock\", \"to\": \"hyper\", \"keyboard\": \"builtin\" }"))
    }

    @Test func flatObjectsInArraysStayOnOneLine() {
        let text = ConfigWriter.text(for: sample)
        let line = text.split(separator: "\n").first { $0.contains("cmd+a") }
        #expect(line?.contains("{ \"keys\"") == true && line?.contains("}") == true)
    }

    @Test func escapesQuotesAndBackslashesButNotSlashes() {
        let text = ConfigWriter.text(for: ["a": "say \"hi\" \\ a/b"])
        #expect(text.contains("\"say \\\"hi\\\" \\\\ a/b\""))
    }

    @Test func booleansAreNotNumbers() {
        let text = ConfigWriter.text(for: ["on": true, "off": false, "one": 1])
        #expect(text.contains("\"on\": true") && text.contains("\"off\": false") && text.contains("\"one\": 1"))
    }
}
