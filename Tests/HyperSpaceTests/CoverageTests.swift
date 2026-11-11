import CoreGraphics
import Testing
@testable import HyperSpace

/// The event tap subscribes to exactly what the config uses.
@Suite struct EventMaskTests {
    private func has(_ mask: CGEventMask, _ type: CGEventType) -> Bool { mask & (CGEventMask(1) << type.rawValue) != 0 }

    @Test func emptyConfigInstallsNoTap() throws {
        #expect(try config("{}").tap.eventMask == 0)
    }

    @Test func bindingsListenToKeys() throws {
        let mask = try config(#"{ "keyboard": { "bindings": [ { "keys": "cmd+alt+h", "action": "focus left" } ] } }"#).tap.eventMask
        #expect(has(mask, .keyDown) && has(mask, .keyUp))
        #expect(!has(mask, .scrollWheel) && !has(mask, .mouseMoved) && !has(mask, .otherMouseDown))
    }

    @Test func mouseFeaturesListenToTheirEvents() throws {
        let scroll = try config(#"{ "mouse": { "reverseScroll": true } }"#).tap.eventMask
        #expect(has(scroll, .scrollWheel) && !has(scroll, .keyDown))
        let buttons = try config(#"{ "mouse": { "buttons": [ { "button": 3, "action": "navigate back" } ] } }"#).tap.eventMask
        #expect(has(buttons, .otherMouseDown) && has(buttons, .otherMouseUp) && !has(buttons, .leftMouseDown))
        let drag = try config(#"{ "mouse": { "dragModifier": "cmd+ctrl" } }"#).tap.eventMask
        #expect(has(drag, .leftMouseDragged) && has(drag, .rightMouseDragged) && has(drag, .leftMouseUp))
    }

    @Test func modifierOnlyCombinationsAlsoReachClicks() throws {
        let mask = try config(#"{ "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] } }"#).tap.eventMask
        #expect(has(mask, .keyDown) && has(mask, .flagsChanged) && has(mask, .leftMouseDown))
    }
}

/// The tap's tables are indexed by key code and modifiers: a key outside them would crash at load.
@Suite struct KeyTableTests {
    @Test func keyCodesFitTheTables() {
        for group in KeyCodes.groups {
            for key in group.keys {
                if let code = key.keyCode { #expect(code < 128, "\(key.name)") }
            }
        }
        #expect(Modifiers.hyper.rawValue < 16)
    }

    @Test func namesAreUnique() {
        var seen: [String: String] = [:]
        for group in KeyCodes.groups {
            for key in group.keys {
                for name in key.names {
                    #expect(seen[name] == nil, "\(name) names both \(seen[name] ?? "") and \(key.name)")
                    seen[name] = key.name
                }
            }
        }
    }
}

/// Every verb of the action language, and its errors.
@Suite struct ActionParseTests {
    @Test func verbsAndArguments() throws {
        let table: [(String, Action)] = [
            ("focus left", .focus(.left)), ("Swap Up", .swap(.up)), ("swap master", .swapMaster),
            ("layout Monocle", .setLayout(.monocle)), ("ratio -0.05", .adjustRatio(-0.05)),
            ("float", .toggleFloat), ("tiling", .toggleTiling), ("accordion", .toggleAccordion), ("retile", .retile),
            ("focus-display", .focusNextDisplay), ("move-workspace-to-display", .moveWorkspaceToNextDisplay),
            ("workspace 3", .workspace(2)), ("workspace back-and-forth", .workspaceBackAndForth),
            ("move-to-workspace 1", .moveToWorkspace(0)),
            ("resize width +50", .resize(width: true, delta: 50)), ("resize height -20", .resize(width: false, delta: -20)),
            ("launch Safari", .launch("Safari")), ("shell open -a Notes", .shell("open -a Notes")),
            ("reload", .reload), ("none", .none), ("navigate back", .navigate(back: true)),
            ("system mission_control", .system(.missionControl)), ("media play_pause", .media(.playPause)),
            ("media next_track", .media(.next)), ("click cmd", .click(.cmd)),
            ("scratchpad", .scratchpad(nil)), ("move-to-scratchpad com.apple.Notes", .moveToScratchpad("com.apple.Notes")),
            ("workspace-overview", .workspaceOverview),
        ]
        for (text, expected) in table {
            #expect(try Action.parse(text) == expected, "\(text)")
        }
        #expect(try Action.parse("key cmd+[") == .sendKey(try KeyCombo.parse("cmd+left_bracket")))
    }

    @Test func errorsAreReported() {
        for text in ["focus sideways", "layout spiral", "ratio more", "workspace 0", "workspace x", "resize depth 5",
                     "launch", "shell ", "navigate up", "system nothing", "media louder", "fly"] {
            #expect(throws: ConfigError.self, "\(text)") { try Action.parse(text) }
        }
    }

    @Test func onlyStepwiseActionsRepeat() throws {
        #expect(try Action.parse("focus left").repeats)
        #expect(try Action.parse("media volume_up").repeats)
        #expect(try !Action.parse("shell say hi").repeats)
        #expect(try !Action.parse("float").repeats)
    }
}

/// Layout math beyond what LayoutTests covers.
@Suite struct LayoutMathTests {
    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func zeroWeightsSplitEvenly() {
        let frames = Layout.split(area, weights: [0, 0], horizontally: true, gap: 0)
        #expect(frames.map(\.width) == [500, 500])
    }

    @Test func wideStacksUnderTheMaster() {
        let frames = Layout.frames(.wide, weights: [1, 1, 1], in: area, gap: 10, ratio: 0.5, focused: 0)
        #expect(frames[0].width == 1000 && frames[0].minY == 0)
        #expect(frames[1].minY == frames[2].minY && frames[1].minY > frames[0].maxY)
        #expect(frames[2].maxX == 1000)
    }

    @Test func monocleFillsTheArea() {
        #expect(Layout.frames(.monocle, weights: [1, 1], in: area, gap: 10, ratio: 0.5) == [area, area])
    }

    @Test func neighborPrefersOverlap() {
        let origin = CGRect(x: 0, y: 0, width: 100, height: 100)
        let candidates: [(String, CGRect)] = [
            ("far-overlapping", CGRect(x: 400, y: 0, width: 100, height: 100)),
            ("near-below", CGRect(x: 150, y: 300, width: 100, height: 100)),
        ]
        #expect(Layout.neighbor(of: origin, .right, among: candidates) == "far-overlapping")
        #expect(Layout.neighbor(of: origin, .left, among: candidates) == nil)
        #expect(Layout.neighbor(of: origin, .down, among: candidates) == "near-below")
    }
}

/// Column operations beyond stacking and the accordion toggle.
@Suite struct ColumnOperationTests {
    @Test func aLoneWindowMovingUpOrDownJoinsItsNeighbour() {
        var layout = ColumnLayout(columns: [[1, 2], [3]])
        layout.move(3, .down)
        #expect(layout.columns.map(\.windows) == [[1, 2, 3]])
        var top = ColumnLayout(columns: [[1], [2, 3]])
        top.move(1, .up)
        #expect(top.columns.map(\.windows) == [[1, 2, 3]])
    }

    @Test func swapExchangesPlaces() {
        var layout = ColumnLayout(columns: [[1, 2], [3]])
        layout.swap(1, 3)
        #expect(layout.columns.map(\.windows) == [[3, 2], [1]])
    }

    @Test func accordionFrontAndNeighbours() {
        var layout = ColumnLayout(columns: [[1, 2, 3]], accordions: [0])
        layout.setFront(2)
        #expect(layout.columns[0].front == 2)
        #expect(layout.accordionNeighbor(of: 2, -1) == 1)
        #expect(layout.accordionNeighbor(of: 2, 1) == 3)
        #expect(layout.accordionNeighbor(of: 3, 1) == nil)
    }
}

/// Small errors the menu shows.
@Suite struct SmallErrorTests {
    @Test func tooManyCombinations() {
        var pool = CarrierPool(excludingHID: [], keyCodes: [])
        for i in 0..<8 { _ = try? pool.carrier(for: "combo\(i)") }
        #expect(throws: ConfigError.self) { try pool.carrier(for: "one more") }
        #expect((try? pool.carrier(for: "combo0"))?.isNew == false)
    }

    @Test func leftAndRightClickCannotBeRemapped() {
        #expect(throws: ConfigError.self) {
            try config(#"{ "mouse": { "buttons": [ { "button": 1, "action": "none" } ] } }"#)
        }
    }
}
