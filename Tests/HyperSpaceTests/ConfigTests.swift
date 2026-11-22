import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// Decoding config.json into `Config`: every section, its defaults, clamps and errors.
@Suite struct ConfigTests {
    @Test func defaultConfigLoads() throws {
        let loaded = try config(DefaultConfig.json)
        #expect(loaded.tap.carriers.map(\.modifiers) == [.hyper])
        #expect(loaded.tap.suppressCapsLock)
        #expect(loaded.tiling.layout == .columns)
        #expect(loaded.tiling.mouseFollowsFocus)
        #expect(try !config(#"{"tiling":{"mouseFollowsFocus":false}}"#).tiling.mouseFollowsFocus)
    }

    @Test func workspaceShortcutsAndRules() throws {
        let loaded = try config(#"""
        { "tiling": {
            "workspaces": [ { "name": "1", "switch": "meh+1", "move": "hyper+1" },
                            { "name": "music", "switch": "meh+m" } ],
            "assign": [ { "app": "com.spotify.client", "workspace": "music" } ] } }
        """#)
        #expect(try action(loaded, "meh+1") == .workspace(0))
        #expect(try action(loaded, "hyper+1") == .moveToWorkspace(0))
        #expect(try action(loaded, "meh+m") == .workspace(1))
        #expect(loaded.tiling.assignments["com.spotify.client"] == 1)
    }

    /// An app rule names its workspace by name, else by 1-based number.
    @Test func assignByNumber() throws {
        let loaded = try config(#"""
        { "tiling": { "workspaces": [ { "name": "web" }, { "name": "code" } ],
                      "assign": [ { "app": "a", "workspace": "2" }, { "app": "b", "workspace": "web" } ] } }
        """#)
        #expect(loaded.tiling.assignments == ["a": 1, "b": 0])
        #expect(configErrorMessage {
            try config(#"{ "tiling": { "workspaces": [ { "name": "web" } ], "assign": [ { "app": "a", "workspace": "2" } ] } }"#)
        } == "app rule for a: no workspace named '2'")
        // A workspace named like a number is found by its name first.
        let named = try config(#"""
        { "tiling": { "workspaces": [ { "name": "2" }, { "name": "x" } ], "assign": [ { "app": "a", "workspace": "2" } ] } }
        """#)
        #expect(named.tiling.assignments["a"] == 0)
    }

    @Test func workspacePins() throws {
        let loaded = try config(#"""
        { "tiling": { "workspaces": [ { "name": "code", "display": "LG" }, { "name": "web", "display": " " },
                                      { "name": "chat", "display": "main" } ] } }
        """#)
        #expect(loaded.tiling.pins == [0: "LG", 2: "main"])
    }

    /// Workspace shortcuts are bound after the bindings: on the same keys, the workspace wins.
    @Test func workspaceShortcutsWinOverAnIdenticalBinding() throws {
        let loaded = try config(#"""
        { "keyboard": { "bindings": [ { "keys": "hyper+1", "action": "focus left" } ] },
          "tiling": { "workspaces": [ { "name": "a", "switch": "hyper+1" } ] } }
        """#)
        #expect(try action(loaded, "hyper+1") == .workspace(0))
        #expect(loaded.tap.actions.count == 1)
    }

    /// The shortcut that shows each workspace, as written: by a binding or the workspace's own, the last winning.
    @Test func switchKeys() throws {
        let loaded = try config(#"""
        { "keyboard": { "bindings": [ { "keys": "meh+3", "action": "workspace 2" },
                                      { "keys": "meh+1", "action": "workspace 1" },
                                      { "keys": "meh+9", "action": "move-to-workspace 1" } ] },
          "tiling": { "workspaces": [ { "name": "a", "switch": "hyper+1" }, { "name": "b" } ] } }
        """#)
        #expect(loaded.tiling.switchKeys == [0: "hyper+1", 1: "meh+3"])
    }

    @Test func twoWorkspacesWithTheSameNameAreAnError() {
        #expect(configErrorMessage {
            try config(#"{ "tiling": { "workspaces": [ { "name": "web" }, { "name": "web" } ] } }"#)
        } == "two workspaces are named 'web'")
        // Unnamed workspaces take their number, which a name can repeat too.
        #expect(configErrorMessage {
            try config(#"{ "tiling": { "workspaces": [ { "name": "2" }, { } ] } }"#)
        } == "two workspaces are named '2'")
    }

    /// Binding the same shortcut twice keeps one action: the last (no orphan left in the list).
    @Test func lastBindingWins() throws {
        let loaded = try config(#"""
        {"keyboard":{"bindings":[{"keys":"hyper+h","action":"focus left"},{"keys":"hyper+h","action":"focus right"}]},
         "mouse":{"buttons":[{"button":3,"action":"navigate back"},{"button":3,"action":"navigate forward"}]}}
        """#)
        #expect(try action(loaded, "hyper+h") == .focus(.right))
        let button = loaded.tap.buttonTable[TapConfig.slot(3, [])]
        #expect(loaded.tap.actions[Int(button)] == .navigate(back: false))
        #expect(loaded.tap.actions.count == 2)
    }

    @Test func spacingIsClamped() throws {
        let tiling = try config(#"{"tiling":{"gap":500,"padding":-3}}"#).tiling
        #expect(tiling.gap == 64)
        #expect(tiling.padding == 0)
        #expect(try config("{}").tiling.gap == TilingConfig().gap)
    }

    @Test func ratioAndAccordionPaddingAreClamped() throws {
        let high = try config(#"{"tiling":{"masterRatio":2,"accordionPadding":500}}"#).tiling
        #expect(high.masterRatio == 0.9 && high.accordionPadding == 200)
        let low = try config(#"{"tiling":{"masterRatio":0,"accordionPadding":-1}}"#).tiling
        #expect(low.masterRatio == 0.1 && low.accordionPadding == 0)
        let inRange = try config(#"{"tiling":{"masterRatio":0.3,"accordionPadding":12}}"#).tiling
        #expect(inRange.masterRatio == 0.3 && inRange.accordionPadding == 12)
        let defaults = try config(#"{"tiling":{}}"#).tiling
        #expect(defaults.masterRatio == TilingConfig.defaultMasterRatio)
        #expect(defaults.accordionPadding == TilingConfig.defaultAccordionPadding)
    }

    @Test func layoutIsReadInAnyCase() throws {
        #expect(try config(#"{"tiling":{"layout":"Monocle"}}"#).tiling.layout == .monocle)
        #expect(try config(#"{"tiling":{"layout":"WIDE"}}"#).tiling.layout == .wide)
        #expect(try config(#"{"tiling":{}}"#).tiling.layout == TilingConfig.defaultLayout)
        #expect(configErrorMessage { try config(#"{"tiling":{"layout":"grid"}}"#) } == "unknown layout 'grid'")
    }

    @Test func ruleForUnknownWorkspaceFails() {
        #expect(configErrorMessage {
            try config(#"{"tiling":{"workspaces":[{"name":"1"}],"assign":[{"app":"x","workspace":"nope"}]}}"#)
        } == "app rule for x: no workspace named 'nope'")
    }

    /// `hyperKey` is the remap of that key to "hyper" on every keyboard.
    @Test func hyperKeyEndToEnd() throws {
        let loaded = try config(#"{ "keyboard": { "hyperKey": "caps_lock" } }"#)
        #expect(loaded.tap.carriers == [TapConfig.Carrier(modifiers: .hyper, keyCode: nil)])
        #expect(loaded.remaps.count == 1)
        #expect(loaded.remaps.first?.from == KeyCodes.lookup("caps_lock")?.hidUsage)
        #expect(loaded.remaps.first?.target == .all)
        #expect(loaded.tap.suppressCapsLock)
        // Empty: no remap at all.
        #expect(try config(#"{ "keyboard": { "hyperKey": "" } }"#).remaps.isEmpty)
    }

    @Test func unknownRemapSourceIsAnError() {
        #expect(configErrorMessage {
            try config(#"{ "keyboard": { "remap": [ { "from": "bogus", "to": "escape" } ] } }"#)
        } == "unknown key 'bogus' in remap")
    }

    @Test func leftAndRightClickCannotBeRemapped() {
        #expect(configErrorMessage {
            try config(#"{ "mouse": { "buttons": [ { "button": 1, "action": "none" } ] } }"#)
        } == "mouse button must be between 2 and 31 (got 1)")
        #expect(configErrorMessage {
            try config(#"{ "mouse": { "buttons": [ { "button": 32, "action": "none" } ] } }"#)
        } == "mouse button must be between 2 and 31 (got 32)")
    }

    /// The config CI installs and the one written on a first launch load, with no shortcut twice.
    @Test(arguments: ["sample", "default"])
    func shippedConfigsLoadWithoutDuplicateShortcuts(which: String) throws {
        let text = which == "sample"
            ? try String(contentsOf: repositoryRoot.appendingPathComponent(".github/ci/sample-config.json"), encoding: .utf8)
            : DefaultConfig.json
        let loaded = try config(text)
        let root = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let bindings = (ConfigWriter.section("keyboard", of: root)["bindings"] as? [[String: Any]] ?? []).compactMap { $0["keys"] as? String }
        let workspaces = ConfigWriter.section("tiling", of: root)["workspaces"] as? [[String: Any]] ?? []
        let keys = bindings + workspaces.flatMap { [$0["switch"] as? String, $0["move"] as? String].compactMap { $0 } }
        let slots = try keys.map { text -> Int in
            let combo = try KeyCombo.parse(text)
            return TapConfig.slot(Int(combo.keyCode), combo.modifiers)
        }
        #expect(!keys.isEmpty)
        #expect(Set(slots).count == slots.count, "a shortcut is bound twice in the \(which) config")
        #expect(loaded.tap.keyTable.filter { $0 >= 0 }.count == keys.count)
    }
}

@Suite struct FloatingWindowTests {
    @Test func titleRules() throws {
        let tiling = try config(#"""
        {"tiling":{"floating":["com.apple.calculator"],
          "floatingWindows":[{"app":"com.autodesk.fusion360","title":"preferences"},{"title":"Picture-in-Picture"},{"title":""}]}}
        """#).tiling
        #expect(tiling.floatingWindows.count == 2)
        #expect(tiling.floats(app: "com.apple.calculator", title: nil))
        #expect(tiling.floats(app: "com.autodesk.fusion360", title: "Preferences"))
        #expect(!tiling.floats(app: "com.autodesk.fusion360", title: "Untitled design"))
        #expect(!tiling.floats(app: "com.apple.Safari", title: "Preferences"))
        #expect(tiling.floats(app: "com.apple.Safari", title: "Picture-in-Picture"))
        #expect(!tiling.floats(app: "com.apple.Safari", title: nil))
    }

    @Test func titleRulesAreNormalized() {
        #expect(TilingConfig.floatingRule(app: "", title: "") == nil)
        #expect(TilingConfig.floatingRule(app: "", title: "Preferences") == FloatingWindowRule(app: nil, title: "Preferences"))
    }
}

/// The helpers the config and the settings pages share, so both read a file the same way.
@Suite struct ConfigHelperTests {
    @Test func numbersAreClampedOrDefaulted() {
        #expect(TilingConfig.value(nil, TilingConfig.spacingRange, 8) == 8)
        #expect(TilingConfig.value(12, TilingConfig.spacingRange, 8) == 12)
        #expect(TilingConfig.value(0.05, TilingConfig.ratioRange, 0.55) == 0.1)
    }

    @Test func edgesDefaultWhenMissingAndFailWhenUnknown() {
        #expect(TrackpadConfig.edge(nil, default: .volume) == .volume)
        #expect(TrackpadConfig.edge("", default: .volume) == .volume)
        #expect(TrackpadConfig.edge("Brightness", default: .volume) == .brightness)
        #expect(TrackpadConfig.edge("loudness", default: .volume) == nil)
    }

    @Test func hyperKeyComesFirst() {
        let remaps = [RawConfig.Remap(from: "a", to: "b", keyboard: "builtin")]
        #expect(RawConfig.Remap.withHyperKey(remaps, hyperKey: nil).map(\.from) == ["a"])
        #expect(RawConfig.Remap.withHyperKey(remaps, hyperKey: "").map(\.from) == ["a"])
        let withHyper = RawConfig.Remap.withHyperKey(remaps, hyperKey: "caps_lock")
        #expect(withHyper.map(\.from) == ["caps_lock", "a"])
        #expect(withHyper[0].to == "hyper" && withHyper[0].keyboard == nil)
    }

    @Test func workspaceNamesFallBackToTheirNumber() {
        #expect(TilingConfig.workspaceName(nil, at: 2) == "3")
        #expect(TilingConfig.workspaceName("", at: 0) == "1")
        #expect(TilingConfig.workspaceName("Web", at: 0) == "Web")
    }
}

@Suite struct ConfigNameTests {
    @Test func enumNamesAreReadInAnyCase() {
        #expect(LayoutKind(configText: "Monocle") == .monocle)
        #expect(EdgeAction(configText: "SEEK") == .seek)
        #expect(SystemAction(configText: "Mission_Control") == .missionControl)
        #expect(MediaKey(configText: "Next_Track") == .next)
        #expect(LayoutKind(configText: "grid") == nil)
    }
}

@Suite struct DragModifierTests {
    /// "+" names nothing: every plain click would become a window drag.
    @Test func aModifierListWithNoModifierIsAnError() {
        #expect(configErrorMessage { try config(#"{ "mouse": { "dragModifier": "+" } }"#) } == "a modifier is missing in '+'")
        #expect(configErrorMessage { try config(#"{ "mouse": { "dragModifier": " + " } }"#) } == "a modifier is missing in ' + '")
    }

    @Test func emptyMeansOffAndModifiersParse() throws {
        #expect(try config(#"{ "mouse": { "dragModifier": "" } }"#).tap.dragModifier == nil)
        #expect(try config(#"{ "mouse": { "dragModifier": "ctrl+alt" } }"#).tap.dragModifier == [.ctrl, .alt])
    }
}

/// The trackpad section: sliders, corners and what the tap watches for them.
@Suite struct TrackpadConfigTests {
    @Test func edgeSlidersConfig() throws {
        let off = try config("{}")
        #expect(off.trackpad == TrackpadConfig())
        #expect(!off.trackpad.isActive)
        let on = try config(#"{ "trackpad": { "edgeSliders": true, "leftEdge": "Volume", "rightEdge": "none" } }"#)
        #expect(on.trackpad == TrackpadConfig(edgeSliders: true, leftEdge: .volume, rightEdge: .none))
        #expect(!on.tap.holdsCornerClicks)
        #expect(on.trackpad.isActive)
        // Pointer moves are watched only with the sliders on, to hold the pointer during a slide.
        #expect(on.tap.holdsPointer && maskHas(on.tap.eventMask, .mouseMoved))
        #expect(!off.tap.holdsPointer && !maskHas(off.tap.eventMask, .mouseMoved))
        #expect(configErrorMessage { try config(#"{ "trackpad": { "leftEdge": "mute" } }"#) }
                == "leftEdge must be volume, brightness, seek or none (got 'mute')")
    }

    @Test func cornersConfig() throws {
        let loaded = try config(#"""
        { "trackpad": { "bottomEdge": "Seek", "corners": { "topRight": "media mute", "topLeft": "none", "bottomLeft": "" } } }
        """#)
        #expect(loaded.trackpad.bottomEdge == .seek)
        #expect(loaded.trackpad.topEdge == .none)
        #expect(loaded.trackpad.corners == [.topRight: .media(.mute)])
        // Corners work with the sliders off; clicks are watched to drop a tap's.
        #expect(loaded.trackpad.isActive && !loaded.trackpad.slidersActive)
        #expect(loaded.tap.holdsPointer && loaded.tap.holdsCornerClicks && maskHas(loaded.tap.eventMask, .leftMouseDown))
        #expect(configErrorMessage { try config(#"{ "trackpad": { "corners": { "middle": "media mute" } } }"#) }
                == "unknown trackpad corner 'middle' (topLeft, topRight, bottomLeft or bottomRight)")
        #expect(configErrorMessage { try config(#"{ "trackpad": { "corners": { "topRight": "explode" } } }"#) }
                == "unknown action 'explode'")
    }
}

/// The event tap subscribes to exactly what the config uses.
@Suite struct EventMaskTests {
    @Test func emptyConfigInstallsNoTap() throws {
        #expect(try config("{}").tap.eventMask == 0)
    }

    @Test func bindingsListenToKeys() throws {
        let mask = try config(#"{ "keyboard": { "bindings": [ { "keys": "cmd+alt+h", "action": "focus left" } ] } }"#).tap.eventMask
        #expect(maskHas(mask, .keyDown) && maskHas(mask, .keyUp))
        #expect(!maskHas(mask, .scrollWheel) && !maskHas(mask, .mouseMoved) && !maskHas(mask, .otherMouseDown))
    }

    @Test func mouseFeaturesListenToTheirEvents() throws {
        let scroll = try config(#"{ "mouse": { "reverseScroll": true } }"#).tap.eventMask
        #expect(maskHas(scroll, .scrollWheel) && !maskHas(scroll, .keyDown))
        let buttons = try config(#"{ "mouse": { "buttons": [ { "button": 3, "action": "navigate back" } ] } }"#).tap.eventMask
        #expect(maskHas(buttons, .otherMouseDown) && maskHas(buttons, .otherMouseUp) && !maskHas(buttons, .leftMouseDown))
        let drag = try config(#"{ "mouse": { "dragModifier": "cmd+ctrl" } }"#).tap.eventMask
        #expect(maskHas(drag, .leftMouseDragged) && maskHas(drag, .rightMouseDragged) && maskHas(drag, .leftMouseUp))
    }

    @Test func modifierOnlyCombinationsAlsoReachClicks() throws {
        let mask = try config(#"{ "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] } }"#).tap.eventMask
        #expect(maskHas(mask, .keyDown) && maskHas(mask, .flagsChanged) && maskHas(mask, .leftMouseDown))
    }
}

@Suite struct HeldModifierMaskTests {
    /// The modifiers of a held combination go on the whole of a click (its drag too) and on
    /// the wheel, not only on the press and the release.
    @Test func aModifierOnlyCombinationAlsoReachesDragsAndTheWheel() throws {
        let mask = try config(#"{ "keyboard": { "remap": [ { "from": "caps_lock", "to": "hyper" } ] } }"#).tap.eventMask
        for type in [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .leftMouseDown, .otherMouseUp] {
            #expect(maskHas(mask, type), "\(type.rawValue)")
        }
    }

    /// A combination with a key is posted as a key: nothing of the mouse is watched for it.
    @Test func aCombinationWithAKeyWatchesNoMouseEvent() throws {
        let mask = try config(#"{ "keyboard": { "remap": [ { "from": "right_command", "to": "cmd+space" } ] } }"#).tap.eventMask
        #expect(maskHas(mask, .keyDown) && !maskHas(mask, .leftMouseDragged) && !maskHas(mask, .scrollWheel) && !maskHas(mask, .leftMouseDown))
    }
}

/// What the menu shows for a config that does not load.
@Suite struct ErrorMessageTests {
    private func loadError(_ json: String) throws -> String? {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            try json.write(to: url, atomically: true, encoding: .utf8)
            do {
                _ = try Config.load(from: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    @Test func wrongTypeNamesThePlace() throws {
        let message = try loadError(#"{ "keyboard": { "bindings": [ { "keys": "hyper+h", "action": "focus left" }, { "keys": 3, "action": "float" } ] } }"#)
        #expect(message == "keyboard.bindings[1].keys: expected text")
    }

    @Test func missingKeyIsNamed() throws {
        let message = try loadError(#"{ "keyboard": { "bindings": [ { "keys": "hyper+h" } ] } }"#)
        #expect(message == #"keyboard.bindings[0]: missing "action""#)
    }

    @Test func brokenJSONSaysSo() throws {
        #expect(try loadError(#"{ "tiling": "#)?.hasPrefix("invalid JSON") == true)
    }
}

/// `Config.describe`: a decoding error in the words of the file.
@Suite struct ConfigDescribeTests {
    /// What decoding `json` as a config reports, or nil when it decodes.
    private func describe(_ json: String) -> String? {
        do {
            _ = try JSONDecoder().decode(RawConfig.self, from: Data(json.utf8))
            return nil
        } catch let error as DecodingError {
            return Config.describe(error)
        } catch {
            return "not a DecodingError: \(error)"
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ name: String) { stringValue = name }
        init(index: Int) { stringValue = "Index \(index)"; intValue = index }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.init(index: intValue) }
    }

    @Test func foundNull() {
        #expect(describe(#"{ "keyboard": { "bindings": [ { "keys": null, "action": "float" } ] } }"#)
                == "keyboard.bindings[0].keys: expected text, found null")
    }

    @Test func expectedTrueOrFalse() {
        #expect(describe(#"{ "tiling": { "enabled": "yes" } }"#) == "tiling.enabled: expected true or false")
    }

    @Test func expectedANumber() {
        #expect(describe(#"{ "tiling": { "gap": "8" } }"#) == "tiling.gap: expected a number")
        #expect(describe(#"{ "mouse": { "buttons": [ { "button": "3", "action": "none" } ] } }"#)
                == "mouse.buttons[0].button: expected a number")
    }

    @Test func expectedAList() {
        #expect(describe(#"{ "tiling": { "floating": "com.apple.Notes" } }"#) == "tiling.floating: expected a list")
        #expect(describe(#"{ "keyboard": { "remap": { "from": "a", "to": "b" } } }"#) == "keyboard.remap: expected a list")
    }

    @Test func expectedAnObject() {
        #expect(describe(#"{ "tiling": 3 }"#) == "tiling: expected an object")
        #expect(describe(#"{ "tiling": { "scratchpad": [] } }"#) == "tiling.scratchpad: expected an object")
    }

    @Test func dataCorruptedWithAPath() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [Key("tiling"), Key("workspaces"), Key(index: 2)],
                                                      debugDescription: "bad value"))
        #expect(Config.describe(error) == "tiling.workspaces[2]: bad value")
        let root = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not JSON"))
        #expect(Config.describe(root) == "invalid JSON: not JSON")
    }

    @Test func aMissingTopLevelKeyHasNoPath() {
        let error = DecodingError.keyNotFound(Key("keys"), .init(codingPath: [], debugDescription: ""))
        #expect(Config.describe(error) == #"missing "keys""#)
    }
}
