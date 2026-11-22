import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

/// The tap's tables are indexed by key code and modifiers: a key outside them would crash at load.
@Suite struct KeyTableTests {
    @Test func keyCodesFitTheTables() {
        for group in KeyCodes.groups {
            for key in group.keys {
                if let code = key.keyCode { #expect(code < TapConfig.keyCodeCount, "\(key.name)") }
            }
        }
        // Each of the 16 modifier combinations has a slot of its own, inside the table, before
        // the next key's.
        let slots = (0...Modifiers.hyper.rawValue).map { TapConfig.slot(TapConfig.keyCodeCount - 1, Modifiers(rawValue: $0)) }
        #expect(Set(slots).count == 16)
        #expect(slots.allSatisfy { $0 < TapConfig.keySlots })
        #expect(TapConfig.slot(0, .hyper) < TapConfig.slot(1, []))
        #expect(TapConfig.slot(TapConfig.buttonCount - 1, .hyper) < TapConfig.buttonSlots)
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

@Suite struct KeyCodeLookupTests {
    private func keyboard(_ usage: UInt64) -> UInt64 { 0x07 << 32 | usage }

    /// A raw HID usage: up to 0xFFFF on the keyboard page, else the full `page << 32 | usage`.
    @Test func hexUsagesOnBothPages() {
        let keyboardKey = KeyCodes.lookup("0x39")
        #expect(keyboardKey?.hidUsage == keyboard(0x39))
        #expect(keyboardKey?.keyCode == nil)
        #expect(KeyCodes.lookup("0X39")?.hidUsage == keyboard(0x39))
        #expect(KeyCodes.lookup("0xC000000E2")?.hidUsage == 0xC_0000_00E2)
        #expect(KeyCodes.lookup("0x") == nil)
        #expect(KeyCodes.lookup("0xZZ") == nil)
        #expect(KeyCodes.lookup("bogus") == nil)
    }

    @Test func namesInAnyCaseAndAliases() {
        #expect(KeyCodes.lookup("ESC")?.keyCode == 0x35)
        #expect(KeyCodes.lookup("left_alt")?.name == "left_option")
    }

    @Test func canonicalName() {
        #expect(KeyCodes.canonicalName("[") == "left_bracket")
        #expect(KeyCodes.canonicalName("ESC") == "escape")
        #expect(KeyCodes.canonicalName("globe") == "fn")
        #expect(KeyCodes.canonicalName("Unknown") == "Unknown")
        #expect(KeyInfo.label(for: "esc") == "Escape")
    }

    /// Keys that share a key code: the first in the table names it (F13 before print_screen).
    @Test func nameForKeyCode() {
        #expect(KeyCodes.name(forKeyCode: 0x69) == "f13")
        #expect(KeyCodes.name(forKeyCode: 0x2A) == "backslash")
        #expect(KeyCodes.name(forKeyCode: 0x00) == "a")
        #expect(KeyCodes.name(forKeyCode: 0x7F) == nil)
    }

    @Test func keyCodeForHID() {
        #expect(KeyCodes.keyCode(forHID: keyboard(0x46)) == 0x69)
        #expect(KeyCodes.keyCode(forHID: keyboard(0x68)) == 0x69)
        #expect(KeyCodes.keyCode(forHID: keyboard(0x04)) == 0x00)
        // Media keys and F21 have no key code.
        #expect(KeyCodes.keyCode(forHID: 0x0C << 32 | 0xE2) == nil)
        #expect(KeyCodes.keyCode(forHID: keyboard(0x70)) == nil)
    }
}

@Suite struct ModifierTests {
    @Test func modifierKeysAreFoundByName() {
        #expect(Modifiers.modifierKey("right_command") == .cmd)
        #expect(Modifiers.modifierKey("left_alt") == .alt)
        #expect(Modifiers.modifierKey("caps_lock") == nil)
        #expect(Modifiers.modifierKey("a") == nil)
        #expect(KeyCodes.modifierKeyCodes.count == 8)
    }

    @Test func modifierParsingMessages() {
        #expect(configErrorMessage { try Modifiers.parse("ctrl+bogus") } == "unknown modifier 'bogus'")
        #expect(configErrorMessage { try KeyCombo.parse("bogus+a") } == "unknown modifier 'bogus' in 'bogus+a'")
        #expect(configErrorMessage { try KeyCombo.parse("hyper+nokey") } == "unknown key in 'hyper+nokey'")
        #expect((try? Modifiers.parse(" ctrl + ⌥ ")) == [.ctrl, .alt])
        #expect((try? RemapTarget.parse("left_shift+right_command")) == .combination([.shift, .cmd], keyCode: nil, keyName: nil))
    }

    @Test func fromEventFlags() {
        #expect(Modifiers(CGEventFlags([.maskCommand, .maskShift, .maskSecondaryFn, .maskAlphaShift])) == [.cmd, .shift])
        #expect(Modifiers(CGEventFlags([])) == [])
        #expect(Modifiers(NSEvent.ModifierFlags([.option, .control, .capsLock, .function])) == [.alt, .ctrl])
        #expect(Modifiers(NSEvent.ModifierFlags([.command, .option, .control, .shift])) == .hyper)
    }

    @Test func cgFlagsRoundTrip() {
        #expect(Modifiers.hyper.cgFlags == [.maskCommand, .maskAlternate, .maskControl, .maskShift])
        #expect(Modifiers().cgFlags == [])
        for raw in 0...Modifiers.hyper.rawValue {
            let modifiers = Modifiers(rawValue: raw)
            #expect(Modifiers(modifiers.cgFlags) == modifiers, "\(raw)")
        }
    }

    @Test func configTextInFixedOrder() throws {
        #expect(Modifiers.hyper.configText == "ctrl+alt+shift+cmd")
        #expect(Modifiers([.cmd, .ctrl]).configText == "ctrl+cmd")
        #expect(Modifiers().configText == "")
        #expect(try Modifiers.parse(Modifiers.meh.configText) == .meh)
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
}

@Suite struct ShortcutKeyTests {
    /// A modifier key, caps lock and fn never come as a key press: a shortcut on one would
    /// load and never fire.
    @Test func aModifierKeyIsNoShortcutKey() {
        for (keys, key) in [("cmd+left_shift", "left_shift"), ("right_command", "right_command"), ("hyper+caps_lock", "caps_lock"),
                            ("ctrl+fn", "fn"), ("left_alt", "left_alt")] {
            #expect(configErrorMessage { try KeyCombo.parse(keys) }
                    == "'\(key)' is a modifier key: it cannot be the key of a shortcut ('\(keys)')")
        }
        #expect(configErrorMessage {
            try config(#"{ "keyboard": { "bindings": [ { "keys": "cmd+left_shift", "action": "retile" } ] } }"#)
        } == "'left_shift' is a modifier key: it cannot be the key of a shortcut ('cmd+left_shift')")
        #expect(configErrorMessage { try KeyCombo.parse("hyper+volume_up") } == "'volume_up' can be remapped but not used in a shortcut")
    }

    /// They stay what they are everywhere else: modifiers of a combination, sources of a remap.
    @Test func modifierKeysStillRemap() throws {
        #expect(try RemapTarget.parse("left_shift+left_control") == .combination([.shift, .ctrl], keyCode: nil, keyName: nil))
        let remapped = try config(#"{ "keyboard": { "remap": [ { "from": "right_command", "to": "cmd+space" } ] } }"#)
        #expect(remapped.remaps.count == 1)
    }

    /// An empty name in a list is refused by the three parsers alike.
    @Test func emptyNamesAreRefusedEverywhere() {
        #expect(configErrorMessage { try Modifiers.parse("ctrl++alt") } == "a modifier is missing in 'ctrl++alt'")
        #expect(configErrorMessage { try Modifiers.parse("ctrl+") } == "a modifier is missing in 'ctrl+'")
        #expect(configErrorMessage { try KeyCombo.parse("ctrl++a") } == "a modifier is missing in 'ctrl++a'")
        #expect(configErrorMessage { try RemapTarget.parse("ctrl++alt") } == "a key is missing in remap target 'ctrl++alt'")
        #expect(configErrorMessage { try RemapTarget.parse("ctrl+") } == "a key is missing in remap target 'ctrl+'")
        #expect(configErrorMessage { try RemapTarget.parse(" ") } == "empty remap target")
        #expect((try? Modifiers.parse("")) == [])
        #expect((try? Modifiers.parse("  ")) == [])
        #expect((try? RemapTarget.parse("cmd+-")) != nil)
    }
}

@Suite struct RemapTargetTests {
    private func hid(_ name: String) -> UInt64 { KeyCodes.lookup(name)!.hidUsage }

    @Test func aSingleKeyIsRemappedInHID() throws {
        #expect(try RemapTarget.parse("escape") == .key(hid("escape")))
        #expect(try RemapTarget.parse("Esc") == .key(hid("escape")))
        #expect(try RemapTarget.parse("none") == .key(0x07 << 32))
        #expect(try RemapTarget.parse("0xC000000E2") == .key(0xC_0000_00E2))
    }

    /// A lone generic modifier is its left key, done in HID; a physical one stays itself.
    @Test func aLoneModifierIsItsLeftKey() throws {
        #expect(try RemapTarget.parse("shift") == .key(hid("left_shift")))
        #expect(try RemapTarget.parse("cmd") == .key(hid("left_command")))
        #expect(try RemapTarget.parse("right_option") == .key(hid("right_option")))
        #expect(try RemapTarget.parse("hyper") == .combination(.hyper, keyCode: nil, keyName: nil))
    }

    @Test func combinations() throws {
        #expect(try RemapTarget.parse("cmd+space") == .combination(.cmd, keyCode: 0x31, keyName: "space"))
        #expect(try RemapTarget.parse("Meh+1") == .combination(.meh, keyCode: 0x12, keyName: "1"))
    }

    @Test func invalidCombinations() {
        #expect(configErrorMessage { try RemapTarget.parse("") } == "empty remap target")
        #expect(configErrorMessage { try RemapTarget.parse("cmd+a+b") } == "'cmd+a+b': a combination can contain only one non-modifier key")
        #expect(configErrorMessage { try RemapTarget.parse("cmd+mute") } == "'mute' cannot be part of a combination")
        #expect(configErrorMessage { try RemapTarget.parse("cmd+bogus") } == "unknown key 'bogus' in 'cmd+bogus'")
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

/// Combinations ride on carrier keys (F13–F20) the config leaves free.
@Suite struct CarrierTests {
    private func firstCarrierName(_ loaded: Config) -> String? {
        loaded.tap.carrierTable.firstIndex { $0 >= 0 }.flatMap { KeyCodes.name(forKeyCode: UInt16($0)) }
    }

    /// Combination carriers must avoid keys used by any shortcut, workspace ones included.
    @Test func carriersAvoidBoundKeys() throws {
        let loaded = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] },
          "tiling": { "workspaces": [ { "name": "a", "switch": "f20" }, { "name": "b", "switch": "f19" } ] } }
        """#)
        #expect(firstCarrierName(loaded) == "f18")
    }

    @Test func sameCombinationSharesCarrier() throws {
        let loaded = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" },
                                   { "from": "right_option", "to": "ctrl+alt+shift" } ] } }
        """#)
        #expect(loaded.tap.carriers.count == 1)
        #expect(Set(loaded.remaps.map(\.to)).count == 1)
    }

    /// `print_screen` shares its key code with F13, and a hex source (`0x46`) is the same key as
    /// its name: either one takes F13 out of the pool.
    @Test(arguments: ["print_screen", "0x46"])
    func aKeyCodeTwinIsNoCarrier(source: String) {
        #expect(configErrorMessage {
            try config(#"""
            { "keyboard": { "remap": [ { "from": "\#(source)", "to": "escape" }, { "from": "caps_lock", "to": "meh" } ] },
              "tiling": { "workspaces": [
                { "switch": "f20" }, { "switch": "f19" }, { "switch": "f18" }, { "switch": "f17" },
                { "switch": "f16" }, { "switch": "f15" }, { "switch": "f14" } ] } }
            """#)
        } == "too many different combinations (at most 8)")
    }

    /// Without a twin F13 is still free.
    @Test func f13IsTheLastCarrier() throws {
        let loaded = try config(#"""
        { "keyboard": { "remap": [ { "from": "caps_lock", "to": "meh" } ] },
          "tiling": { "workspaces": [
            { "switch": "f20" }, { "switch": "f19" }, { "switch": "f18" }, { "switch": "f17" },
            { "switch": "f16" }, { "switch": "f15" }, { "switch": "f14" } ] } }
        """#)
        #expect(firstCarrierName(loaded) == "f13")
    }

    @Test func carriersFollowTheLayout() throws {
        let loaded = try config(#"{ "keyboard": { "remap": [ { "from": "right_command", "to": "cmd+-" } ] } }"#)
        let minus = try KeyCombo.parse("-").keyCode
        #expect(loaded.tap.carriers.map(\.keyCode) == [minus])
        let translated = loaded.tap.translated { $0 == minus ? 0x2C : $0 }
        #expect(translated.carriers.map(\.keyCode) == [0x2C])
        #expect(translated != loaded.tap)
        #expect(translated.translated { $0 } == translated)
    }

    @Test func tooManyCombinations() {
        var pool = CarrierPool(excludingHID: [], keyCodes: [])
        for i in 0..<8 { _ = try? pool.carrier(for: "combo\(i)") }
        #expect(configErrorMessage { try pool.carrier(for: "one more") } == "too many different combinations (at most 8)")
        #expect((try? pool.carrier(for: "combo0"))?.isNew == false)
    }
}

@Suite struct KeyboardTargetTests {
    @Test func targetsAreReadFromTheirText() {
        #expect(KeyboardTarget(nil) == .all)
        #expect(KeyboardTarget("") == .all)
        #expect(KeyboardTarget("ALL") == .all)
        #expect(KeyboardTarget("builtin") == .builtIn)
        #expect(KeyboardTarget("Built-in") == .builtIn)
        #expect(KeyboardTarget("internal") == .builtIn)
        #expect(KeyboardTarget("External") == .external)
        #expect(KeyboardTarget("Magic Keyboard") == .product("Magic Keyboard"))
    }

    @Test func whichKeyboardsMatch() {
        #expect(KeyboardTarget.product("magic").matches(product: "Magic Keyboard", builtIn: false))
        #expect(!KeyboardTarget.product("logi").matches(product: "Magic Keyboard", builtIn: false))
        #expect(KeyboardTarget.builtIn.matches(product: "Apple Internal Keyboard", builtIn: true))
        #expect(!KeyboardTarget.external.matches(product: "Apple Internal Keyboard", builtIn: true))
    }
}

@Suite struct KeyboardMappingTests {
    private func pairs(_ rules: [RemapRule], product: String = "Magic Keyboard", builtIn: Bool = false) -> [UInt64: UInt64] {
        var result: [UInt64: UInt64] = [:]
        for case let entry as NSDictionary in KeyboardRemapper.mapping(rules, product: product, builtIn: builtIn) {
            let from = (entry["HIDKeyboardModifierMappingSrc"] as? NSNumber)?.uint64Value ?? 0
            result[from] = (entry["HIDKeyboardModifierMappingDst"] as? NSNumber)?.uint64Value
        }
        return result
    }

    @Test func moreSpecificRuleWinsInEitherOrder() {
        let generic = RemapRule(from: 1, to: 10, target: .all)
        let specific = RemapRule(from: 1, to: 20, target: .product("magic"))
        #expect(pairs([generic, specific]) == [1: 20])
        #expect(pairs([specific, generic]) == [1: 20])
    }

    @Test func lastInFileWinsAtEqualSpecificity() {
        #expect(pairs([RemapRule(from: 1, to: 10, target: .all), RemapRule(from: 1, to: 20, target: .all)]) == [1: 20])
        #expect(pairs([RemapRule(from: 1, to: 10, target: .external), RemapRule(from: 1, to: 20, target: .external)]) == [1: 20])
    }

    @Test func rulesForOtherKeyboardsAreExcluded() {
        let rules = [
            RemapRule(from: 1, to: 10, target: .product("Logitech")),
            RemapRule(from: 2, to: 20, target: .builtIn),
            RemapRule(from: 3, to: 30, target: .external),
        ]
        #expect(pairs(rules) == [3: 30])
        #expect(pairs(rules, product: "Apple Internal Keyboard", builtIn: true) == [2: 20])
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

@Suite struct KeyboardLockTests {
    @Test func remaining() {
        let now = Date()
        #expect(KeyboardLock.remaining(until: now + 161, now: now) == "2:41")
        #expect(KeyboardLock.remaining(until: now + 0.2, now: now) == "0:01")
        #expect(KeyboardLock.remaining(until: now - 5, now: now) == "0:00")
        #expect(KeyboardLock.label(minutes: 0) == "Never")
    }
}
