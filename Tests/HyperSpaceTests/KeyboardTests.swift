import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct KeyboardLockTests {
    @Test func remaining() {
        let now = Date()
        #expect(KeyboardLock.remaining(until: now + 161, now: now) == "2:41")
        #expect(KeyboardLock.remaining(until: now + 0.2, now: now) == "0:01")
        #expect(KeyboardLock.remaining(until: now - 5, now: now) == "0:00")
        #expect(KeyboardLock.label(minutes: 0) == "Never")
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

    @Test func modifierParsingMessages() {
        #expect(throws: ConfigError.self) { try Modifiers.parse("ctrl+bogus") }
        #expect(throws: ConfigError.self) { try KeyCombo.parse("bogus+a") }
        #expect((try? Modifiers.parse(" ctrl + ⌥ ")) == [.ctrl, .alt])
        #expect((try? RemapTarget.parse("left_shift+right_command")) == .combination([.shift, .cmd], keyCode: nil, keyName: nil))
        #expect(KeyCodes.modifierKeyCodes.count == 8)
    }

    @Test func titleRulesAndNamesAreNormalized() {
        #expect(TilingConfig.floatingRule(app: "", title: "") == nil)
        #expect(TilingConfig.floatingRule(app: "", title: "Preferences") == FloatingWindowRule(app: nil, title: "Preferences"))
        #expect(TilingConfig.workspaceName("", at: 1) == "2")
        #expect(TilingConfig.workspaceName("web", at: 1) == "web")
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
