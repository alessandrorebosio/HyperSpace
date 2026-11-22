import ApplicationServices
import Foundation
import Testing
@testable import HyperSpace

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
            ("media next_track", .media(.next)), ("click cmd", .click(.cmd)), ("click", .click([])),
            ("scratchpad", .scratchpad(nil)), ("scratchpad com.apple.Notes", .scratchpad("com.apple.Notes")),
            ("move-to-scratchpad", .moveToScratchpad(nil)),
            ("move-to-scratchpad com.apple.Notes", .moveToScratchpad("com.apple.Notes")),
            ("workspace-overview", .workspaceOverview), ("  float  ", .toggleFloat),
        ]
        for (text, expected) in table {
            #expect(try Action.parse(text) == expected, "\(text)")
        }
        #expect(try Action.parse("key cmd+[") == .sendKey(try KeyCombo.parse("cmd+left_bracket")))
    }

    /// The messages listed under "Typical error messages" in docs/05.
    @Test func errorsAreReported() {
        let cases = [
            ("focus sideways", "expected left/right/up/down in 'focus sideways'"),
            ("layout spiral", "unknown layout in 'layout spiral'"),
            ("ratio more", "expected a number in 'ratio more'"),
            ("workspace 0", "expected a workspace number in 'workspace 0'"),
            ("workspace x", "expected a workspace number in 'workspace x'"),
            ("resize depth 5", "expected 'resize width|height <points>' in 'resize depth 5'"),
            ("launch", "missing argument in 'launch'"),
            ("shell ", "missing argument in 'shell '"),
            ("key", "missing argument in 'key'"),
            ("navigate up", "expected back/forward in 'navigate up'"),
            ("system nothing", "unknown system action in 'system nothing'"),
            ("media louder", "unknown media key in 'media louder'"),
            ("fly", "unknown action 'fly'"),
            ("display", "unknown action 'display'"),
            ("layout next", "unknown layout in 'layout next'"),
            ("click bogus", "unknown modifier 'bogus'"),
        ]
        for (text, message) in cases {
            #expect(configErrorMessage { try Action.parse(text) } == message, "\(text)")
        }
    }

    @Test func onlyStepwiseActionsRepeat() throws {
        #expect(try Action.parse("focus left").repeats)
        #expect(try Action.parse("swap up").repeats)
        #expect(try Action.parse("resize width +10").repeats)
        #expect(try Action.parse("ratio 0.05").repeats)
        #expect(try Action.parse("key cmd+z").repeats)
        #expect(try !Action.parse("shell say hi").repeats)
        #expect(try !Action.parse("float").repeats)
        #expect(try !Action.parse("workspace 1").repeats)
    }
}

@Suite struct ActionNumberTests {
    /// "nan" and "inf" read as numbers: a ratio or a size cannot be one.
    @Test func ratioAndResizeNeedFiniteNumbers() {
        for text in ["ratio nan", "ratio inf"] {
            #expect(configErrorMessage { try Action.parse(text) } == "expected a number in '\(text)'")
        }
        for text in ["resize width inf", "resize height -infinity", "resize width nan"] {
            #expect(configErrorMessage { try Action.parse(text) } == "expected 'resize width|height <points>' in '\(text)'")
        }
        #expect((try? Action.parse("ratio -0.05")) == .adjustRatio(-0.05))
        #expect((try? Action.parse("resize width +20")) == .resize(width: true, delta: 20))
    }
}

@Suite struct MediaRepeatTests {
    /// Holding a shortcut repeats the keys that move in steps; the ones that toggle or skip
    /// would flap or run through the tracks.
    @Test func onlyVolumeAndBrightnessRepeat() throws {
        for name in ["volume_up", "volume_down", "brightness_up", "brightness_down"] {
            #expect(try Action.parse("media \(name)").repeats, "\(name)")
        }
        for name in ["play_pause", "mute", "next", "previous", "next_track"] {
            #expect(try !Action.parse("media \(name)").repeats, "\(name)")
        }
    }
}

@Suite struct NavigationMatcherTests {

    struct Item: CustomTestStringConvertible, Sendable {
        let char: String?
        let modifiers: Int?
        let title: String?
        let identifier: String?
        let back: Bool
        let forward: Bool
        var testDescription: String { "\(char ?? "-") \(modifiers.map(String.init) ?? "-") \(title ?? "-") \(identifier ?? "-")" }
    }

    static let command = 0
    static let ctrlNoCmd = Navigation.Shortcut.control | Navigation.Shortcut.noCommand
    static let shiftCtrlNoCmd = Navigation.Shortcut.shift | ctrlNoCmd

    @Test(arguments: [
        // By identifier, whatever the shortcut.
        Item(char: nil, modifiers: nil, title: nil, identifier: "goBack:", back: true, forward: false),
        Item(char: nil, modifiers: nil, title: "Whatever", identifier: "GoForward", back: false, forward: true),
        // By unlocalized shortcut.
        Item(char: "[", modifiers: NavigationMatcherTests.command, title: nil, identifier: nil, back: true, forward: false),
        Item(char: "]", modifiers: NavigationMatcherTests.command, title: nil, identifier: nil, back: false, forward: true),
        Item(char: "-", modifiers: NavigationMatcherTests.ctrlNoCmd, title: nil, identifier: nil, back: true, forward: false),
        Item(char: "-", modifiers: NavigationMatcherTests.shiftCtrlNoCmd, title: nil, identifier: nil, back: false, forward: true),
        Item(char: "-", modifiers: NavigationMatcherTests.command, title: nil, identifier: nil, back: false, forward: false),
        Item(char: "[", modifiers: Navigation.Shortcut.shift, title: nil, identifier: nil, back: false, forward: false),
        // By title, in any case, only with a shortcut.
        Item(char: "Ò", modifiers: NavigationMatcherTests.command, title: "Indietro", identifier: nil, back: true, forward: false),
        Item(char: "+", modifiers: NavigationMatcherTests.command, title: "Go Forward", identifier: nil, back: false, forward: true),
        Item(char: nil, modifiers: nil, title: "Back", identifier: nil, back: false, forward: false),
        Item(char: "b", modifiers: NavigationMatcherTests.command, title: "Bookmarks", identifier: nil, back: false, forward: false),
        Item(char: nil, modifiers: nil, title: nil, identifier: nil, back: false, forward: false),
    ])
    func matches(item: Item) {
        #expect(Navigation.backMatcher.matches(char: item.char, modifiers: item.modifiers,
                                               title: item.title, identifier: item.identifier) == item.back)
        #expect(Navigation.forwardMatcher.matches(char: item.char, modifiers: item.modifiers,
                                                  title: item.title, identifier: item.identifier) == item.forward)
    }
}

@Suite struct NavigationPressTests {
    /// Only a press that went through counts: any error falls back to the mouse button.
    @Test func onlySuccessIsAPress() {
        #expect(Navigation.pressed(.success))
        for error in [AXError.invalidUIElement, .cannotComplete, .actionUnsupported, .failure, .notImplemented, .apiDisabled] {
            #expect(!Navigation.pressed(error), "\(error.rawValue)")
        }
    }
}
