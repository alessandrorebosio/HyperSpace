import Foundation
import Testing
@testable import HyperSpace

@Suite struct DragModifierTests {
    @Test func aModifierListWithNoModifierIsAnError() {
        // "+" names nothing: every plain click would become a window drag.
        #expect(throws: ConfigError.self) { try config(#"{ "mouse": { "dragModifier": "+" } }"#) }
        #expect(throws: ConfigError.self) { try config(#"{ "mouse": { "dragModifier": " + " } }"#) }
    }

    @Test func emptyMeansOffAndModifiersParse() throws {
        #expect(try config(#"{ "mouse": { "dragModifier": "" } }"#).tap.dragModifier == nil)
        #expect(try config(#"{ "mouse": { "dragModifier": "ctrl+alt" } }"#).tap.dragModifier == [.ctrl, .alt])
    }
}

@Suite struct HexRemapSourceTests {
    /// A hex source is the same key as its name: `0x46` is `print_screen`, which shares its key
    /// code with F13, so F13 is no carrier either.
    @Test func aHexSourceTakesItsKeyCodeTwinOutOfTheCarrierPool() {
        #expect(throws: ConfigError.self) {
            try config(#"""
            { "keyboard": { "remap": [ { "from": "0x46", "to": "escape" }, { "from": "caps_lock", "to": "meh" } ] },
              "tiling": { "workspaces": [
                { "switch": "f20" }, { "switch": "f19" }, { "switch": "f18" }, { "switch": "f17" },
                { "switch": "f16" }, { "switch": "f15" }, { "switch": "f14" } ] } }
            """#)
        }
    }

    /// Without the hex source F13 is still free.
    @Test func f13IsTheLastCarrier() throws {
        let config = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] },
          "tiling": { "workspaces": [
            { "switch": "f20" }, { "switch": "f19" }, { "switch": "f18" }, { "switch": "f17" },
            { "switch": "f16" }, { "switch": "f15" }, { "switch": "f14" } ] } }
        """#)
        let carrier = config.tap.carrierTable.firstIndex { $0 >= 0 }
        #expect(carrier.flatMap { KeyCodes.name(forKeyCode: UInt16($0)) } == "f13")
    }
}

@Suite struct SingleModifierKeyTests {
    @Test(arguments: [
        (Modifiers.cmd, "left_command"), (.alt, "left_option"), (.ctrl, "left_control"), (.shift, "left_shift"),
    ])
    func oneModifierIsItsLeftKey(modifiers: Modifiers, key: String) {
        #expect(RemapTarget.singleModifierKey(modifiers) == key)
    }

    @Test(arguments: [Modifiers(), [.cmd, .shift], .meh, .hyper])
    func noneOrSeveralAreNoKey(modifiers: Modifiers) {
        #expect(RemapTarget.singleModifierKey(modifiers) == nil)
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

@Suite struct KeyboardLayoutTableTests {
    /// The tables come from `KeyCodes`: the ANSI symbol keys and the keypad.
    @Test func symbolKeysAreThePunctuationKeys() {
        let expected: [UInt16: Character] = [
            0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";",
            0x27: "'", 0x32: "`", 0x2B: ",", 0x2F: ".", 0x2C: "/",
        ]
        #expect(KeyboardLayout.symbols == expected)
    }

    @Test func keypadKeys() {
        let expected: Set<UInt16> = [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52, 0x53, 0x54,
                                     0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C, 0x5F]
        #expect(KeyboardLayout.keypad == expected)
    }
}

/// Both run their work on the main queue: a block queued after theirs runs after it.
@Suite @MainActor struct SchedulingTests {
    /// Waits until the main queue has run what was queued before, plus `delay` seconds.
    private func drainMain(after delay: TimeInterval = 0) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { continuation.resume() }
        }
    }

    @Test func coalescerRunsTheFirstWorkOncePerBurst() async {
        let coalescer = Coalescer()
        var runs: [Int] = []
        coalescer.schedule { runs.append(1) }
        coalescer.schedule { runs.append(2) }
        #expect(runs.isEmpty)
        await drainMain()
        #expect(runs == [1])
        coalescer.schedule { runs.append(3) }
        await drainMain()
        #expect(runs == [1, 3])
    }

    @Test func debouncerRunsTheLastWork() async {
        let debouncer = Debouncer(delay: 0.01)
        var runs: [Int] = []
        debouncer.schedule { runs.append(1) }
        debouncer.schedule { runs.append(2) }
        #expect(debouncer.isPending)
        await drainMain(after: 0.05)
        #expect(runs == [2])
        #expect(!debouncer.isPending)
    }

    @Test func aCancelledDebouncerRunsNothing() async {
        let debouncer = Debouncer(delay: 0.01)
        var runs = 0
        debouncer.schedule { runs += 1 }
        debouncer.cancel()
        #expect(!debouncer.isPending)
        await drainMain(after: 0.05)
        #expect(runs == 0)
    }
}
