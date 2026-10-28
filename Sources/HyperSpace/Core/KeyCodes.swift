import CoreGraphics
import Foundation

/// A physical key: its macOS virtual key code (what event taps see, used by
/// bindings) and its full HID usage, `page << 32 | usage` (used by remapping).
/// Keys that macOS never turns into key events (media keys, F21–F24) have no key code.
struct Key {
    let keyCode: UInt16?
    let hidUsage: UInt64?
}

struct KeyInfo {
    let names: [String]
    let keyCode: UInt16?
    let hidUsage: UInt64

    init(_ names: [String], _ keyCode: UInt16?, _ hidUsage: UInt64) {
        self.names = names
        self.keyCode = keyCode
        self.hidUsage = hidUsage
    }

    var name: String { names[0] }

    /// "left_command" → "Left Command", "f5" → "F5".
    var label: String { KeyInfo.label(for: name) }

    static func label(for name: String) -> String {
        name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

enum KeyCodes {
    /// A name from the table, or a raw HID usage for anything else:
    /// "0x39" (keyboard page) or "0xC000000E2" (any page, `page << 32 | usage`).
    static func lookup(_ name: String) -> Key? {
        let lowered = name.lowercased()
        if let key = table[lowered] { return key }
        guard lowered.hasPrefix("0x"), let raw = UInt64(lowered.dropFirst(2), radix: 16) else { return nil }
        return Key(keyCode: nil, hidUsage: raw <= 0xFFFF ? keyboard(raw) : raw)
    }

    private static func keyboard(_ usage: UInt64) -> UInt64 { 0x07 << 32 | usage }
    private static func consumer(_ usage: UInt64) -> UInt64 { 0x0C << 32 | usage }

    /// Every named key, grouped for menus. The first name of a key is its canonical name.
    static let groups: [(title: String, keys: [KeyInfo])] = [
        ("Letters & Digits", [
            KeyInfo(["a"], 0x00, keyboard(0x04)), KeyInfo(["b"], 0x0B, keyboard(0x05)), KeyInfo(["c"], 0x08, keyboard(0x06)),
            KeyInfo(["d"], 0x02, keyboard(0x07)), KeyInfo(["e"], 0x0E, keyboard(0x08)), KeyInfo(["f"], 0x03, keyboard(0x09)),
            KeyInfo(["g"], 0x05, keyboard(0x0A)), KeyInfo(["h"], 0x04, keyboard(0x0B)), KeyInfo(["i"], 0x22, keyboard(0x0C)),
            KeyInfo(["j"], 0x26, keyboard(0x0D)), KeyInfo(["k"], 0x28, keyboard(0x0E)), KeyInfo(["l"], 0x25, keyboard(0x0F)),
            KeyInfo(["m"], 0x2E, keyboard(0x10)), KeyInfo(["n"], 0x2D, keyboard(0x11)), KeyInfo(["o"], 0x1F, keyboard(0x12)),
            KeyInfo(["p"], 0x23, keyboard(0x13)), KeyInfo(["q"], 0x0C, keyboard(0x14)), KeyInfo(["r"], 0x0F, keyboard(0x15)),
            KeyInfo(["s"], 0x01, keyboard(0x16)), KeyInfo(["t"], 0x11, keyboard(0x17)), KeyInfo(["u"], 0x20, keyboard(0x18)),
            KeyInfo(["v"], 0x09, keyboard(0x19)), KeyInfo(["w"], 0x0D, keyboard(0x1A)), KeyInfo(["x"], 0x07, keyboard(0x1B)),
            KeyInfo(["y"], 0x10, keyboard(0x1C)), KeyInfo(["z"], 0x06, keyboard(0x1D)),
            KeyInfo(["1"], 0x12, keyboard(0x1E)), KeyInfo(["2"], 0x13, keyboard(0x1F)), KeyInfo(["3"], 0x14, keyboard(0x20)),
            KeyInfo(["4"], 0x15, keyboard(0x21)), KeyInfo(["5"], 0x17, keyboard(0x22)), KeyInfo(["6"], 0x16, keyboard(0x23)),
            KeyInfo(["7"], 0x1A, keyboard(0x24)), KeyInfo(["8"], 0x1C, keyboard(0x25)), KeyInfo(["9"], 0x19, keyboard(0x26)),
            KeyInfo(["0"], 0x1D, keyboard(0x27)),
        ]),
        ("Editing", [
            KeyInfo(["return", "enter"], 0x24, keyboard(0x28)),
            KeyInfo(["escape", "esc"], 0x35, keyboard(0x29)),
            KeyInfo(["delete", "backspace"], 0x33, keyboard(0x2A)),
            KeyInfo(["tab"], 0x30, keyboard(0x2B)),
            KeyInfo(["space"], 0x31, keyboard(0x2C)),
            KeyInfo(["forward_delete"], 0x75, keyboard(0x4C)),
            KeyInfo(["insert", "help"], 0x72, keyboard(0x49)),
            KeyInfo(["application", "menu"], 0x6E, keyboard(0x65)),
        ]),
        ("Punctuation", [
            KeyInfo(["minus", "-"], 0x1B, keyboard(0x2D)),
            KeyInfo(["equal", "="], 0x18, keyboard(0x2E)),
            KeyInfo(["left_bracket", "["], 0x21, keyboard(0x2F)),
            KeyInfo(["right_bracket", "]"], 0x1E, keyboard(0x30)),
            KeyInfo(["backslash", "\\"], 0x2A, keyboard(0x31)),
            KeyInfo(["non_us_pound"], 0x2A, keyboard(0x32)),
            KeyInfo(["semicolon", ";"], 0x29, keyboard(0x33)),
            KeyInfo(["quote", "'"], 0x27, keyboard(0x34)),
            KeyInfo(["grave", "`"], 0x32, keyboard(0x35)),
            KeyInfo(["comma", ","], 0x2B, keyboard(0x36)),
            KeyInfo(["period", "."], 0x2F, keyboard(0x37)),
            KeyInfo(["slash", "/"], 0x2C, keyboard(0x38)),
            KeyInfo(["section", "§", "non_us_backslash"], 0x0A, keyboard(0x64)),
        ]),
        ("Navigation", [
            KeyInfo(["home"], 0x73, keyboard(0x4A)),
            KeyInfo(["page_up"], 0x74, keyboard(0x4B)),
            KeyInfo(["end"], 0x77, keyboard(0x4D)),
            KeyInfo(["page_down"], 0x79, keyboard(0x4E)),
            KeyInfo(["right"], 0x7C, keyboard(0x4F)),
            KeyInfo(["left"], 0x7B, keyboard(0x50)),
            KeyInfo(["down"], 0x7D, keyboard(0x51)),
            KeyInfo(["up"], 0x7E, keyboard(0x52)),
        ]),
        ("Function Keys", [
            KeyInfo(["f1"], 0x7A, keyboard(0x3A)), KeyInfo(["f2"], 0x78, keyboard(0x3B)), KeyInfo(["f3"], 0x63, keyboard(0x3C)),
            KeyInfo(["f4"], 0x76, keyboard(0x3D)), KeyInfo(["f5"], 0x60, keyboard(0x3E)), KeyInfo(["f6"], 0x61, keyboard(0x3F)),
            KeyInfo(["f7"], 0x62, keyboard(0x40)), KeyInfo(["f8"], 0x64, keyboard(0x41)), KeyInfo(["f9"], 0x65, keyboard(0x42)),
            KeyInfo(["f10"], 0x6D, keyboard(0x43)), KeyInfo(["f11"], 0x67, keyboard(0x44)), KeyInfo(["f12"], 0x6F, keyboard(0x45)),
            KeyInfo(["f13"], 0x69, keyboard(0x68)), KeyInfo(["f14"], 0x6B, keyboard(0x69)), KeyInfo(["f15"], 0x71, keyboard(0x6A)),
            KeyInfo(["f16"], 0x6A, keyboard(0x6B)), KeyInfo(["f17"], 0x40, keyboard(0x6C)), KeyInfo(["f18"], 0x4F, keyboard(0x6D)),
            KeyInfo(["f19"], 0x50, keyboard(0x6E)), KeyInfo(["f20"], 0x5A, keyboard(0x6F)),
            KeyInfo(["f21"], nil, keyboard(0x70)), KeyInfo(["f22"], nil, keyboard(0x71)),
            KeyInfo(["f23"], nil, keyboard(0x72)), KeyInfo(["f24"], nil, keyboard(0x73)),
        ]),
        ("PC Keys", [
            KeyInfo(["print_screen"], 0x69, keyboard(0x46)),
            KeyInfo(["scroll_lock"], 0x6B, keyboard(0x47)),
            KeyInfo(["pause"], 0x71, keyboard(0x48)),
        ]),
        ("Modifiers", [
            KeyInfo(["caps_lock"], 0x39, keyboard(0x39)),
            KeyInfo(["left_control"], 0x3B, keyboard(0xE0)),
            KeyInfo(["left_shift"], 0x38, keyboard(0xE1)),
            KeyInfo(["left_option", "left_alt"], 0x3A, keyboard(0xE2)),
            KeyInfo(["left_command", "left_cmd"], 0x37, keyboard(0xE3)),
            KeyInfo(["right_control"], 0x3E, keyboard(0xE4)),
            KeyInfo(["right_shift"], 0x3C, keyboard(0xE5)),
            KeyInfo(["right_option", "right_alt"], 0x3D, keyboard(0xE6)),
            KeyInfo(["right_command", "right_cmd"], 0x36, keyboard(0xE7)),
            KeyInfo(["fn", "globe"], 0x3F, 0xFF << 32 | 0x03),
        ]),
        ("Keypad", [
            KeyInfo(["keypad_0"], 0x52, keyboard(0x62)), KeyInfo(["keypad_1"], 0x53, keyboard(0x59)),
            KeyInfo(["keypad_2"], 0x54, keyboard(0x5A)), KeyInfo(["keypad_3"], 0x55, keyboard(0x5B)),
            KeyInfo(["keypad_4"], 0x56, keyboard(0x5C)), KeyInfo(["keypad_5"], 0x57, keyboard(0x5D)),
            KeyInfo(["keypad_6"], 0x58, keyboard(0x5E)), KeyInfo(["keypad_7"], 0x59, keyboard(0x5F)),
            KeyInfo(["keypad_8"], 0x5B, keyboard(0x60)), KeyInfo(["keypad_9"], 0x5C, keyboard(0x61)),
            KeyInfo(["keypad_period"], 0x41, keyboard(0x63)),
            KeyInfo(["keypad_enter"], 0x4C, keyboard(0x58)),
            KeyInfo(["keypad_plus"], 0x45, keyboard(0x57)),
            KeyInfo(["keypad_minus"], 0x4E, keyboard(0x56)),
            KeyInfo(["keypad_multiply"], 0x43, keyboard(0x55)),
            KeyInfo(["keypad_divide"], 0x4B, keyboard(0x54)),
            KeyInfo(["keypad_equal"], 0x51, keyboard(0x67)),
            KeyInfo(["keypad_comma"], 0x5F, keyboard(0x85)),
            KeyInfo(["keypad_clear", "num_lock"], 0x47, keyboard(0x53)),
        ]),
        ("International", [
            KeyInfo(["international1", "jis_underscore"], 0x5E, keyboard(0x87)),
            KeyInfo(["international3", "jis_yen"], 0x5D, keyboard(0x89)),
            KeyInfo(["lang1", "kana"], 0x68, keyboard(0x90)),
            KeyInfo(["lang2", "eisu"], 0x66, keyboard(0x91)),
        ]),
        ("Media", [
            KeyInfo(["mute"], nil, consumer(0xE2)),
            KeyInfo(["volume_up"], nil, consumer(0xE9)),
            KeyInfo(["volume_down"], nil, consumer(0xEA)),
            KeyInfo(["play_pause"], nil, consumer(0xCD)),
            KeyInfo(["next_track"], nil, consumer(0xB5)),
            KeyInfo(["previous_track"], nil, consumer(0xB6)),
            KeyInfo(["eject"], nil, consumer(0xB8)),
            KeyInfo(["brightness_up"], nil, consumer(0x6F)),
            KeyInfo(["brightness_down"], nil, consumer(0x70)),
        ]),
        ("Special", [
            KeyInfo(["none", "disabled"], nil, keyboard(0x00)),
        ]),
    ]

    private static let table: [String: Key] = {
        var table: [String: Key] = [:]
        for (_, keys) in groups {
            for key in keys {
                for name in key.names { table[name] = Key(keyCode: key.keyCode, hidUsage: key.hidUsage) }
            }
        }
        return table
    }()

    private static let namesByKeyCode: [UInt16: String] = {
        var names: [UInt16: String] = [:]
        for (_, keys) in groups {
            for key in keys { if let code = key.keyCode, names[code] == nil { names[code] = key.name } }
        }
        return names
    }()

    /// Canonical name of the key that produced an event with this virtual key code.
    static func name(forKeyCode code: UInt16) -> String? {
        namesByKeyCode[code]
    }
}

struct Modifiers: OptionSet, Hashable {
    let rawValue: UInt8

    static let cmd = Modifiers(rawValue: 1 << 0)
    static let alt = Modifiers(rawValue: 1 << 1)
    static let ctrl = Modifiers(rawValue: 1 << 2)
    static let shift = Modifiers(rawValue: 1 << 3)
    static let hyper: Modifiers = [.cmd, .alt, .ctrl, .shift]

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ flags: CGEventFlags) {
        var mods: Modifiers = []
        if flags.contains(.maskCommand) { mods.insert(.cmd) }
        if flags.contains(.maskAlternate) { mods.insert(.alt) }
        if flags.contains(.maskControl) { mods.insert(.ctrl) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        self = mods
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.cmd) { flags.insert(.maskCommand) }
        if contains(.alt) { flags.insert(.maskAlternate) }
        if contains(.ctrl) { flags.insert(.maskControl) }
        if contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    static func token(_ token: String) -> Modifiers? {
        switch token.lowercased() {
        case "cmd", "command", "⌘": return .cmd
        case "alt", "opt", "option", "⌥": return .alt
        case "ctrl", "control", "⌃": return .ctrl
        case "shift", "⇧": return .shift
        case "hyper": return .hyper
        case "meh": return [.alt, .ctrl, .shift]
        default: return nil
        }
    }

    /// The modifier a physical modifier key produces ("left_shift" → .shift).
    static func modifierKey(_ name: String) -> Modifiers? {
        switch name.lowercased() {
        case "left_command", "right_command", "left_cmd", "right_cmd": return .cmd
        case "left_option", "right_option", "left_alt", "right_alt": return .alt
        case "left_control", "right_control": return .ctrl
        case "left_shift", "right_shift": return .shift
        default: return nil
        }
    }

    /// Config text, e.g. "ctrl+alt".
    var configText: String {
        [(Modifiers.ctrl, "ctrl"), (.alt, "alt"), (.shift, "shift"), (.cmd, "cmd")]
            .filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// ⌃⌥⇧⌘ in macOS menu order.
    var symbols: String {
        (contains(.ctrl) ? "⌃" : "") + (contains(.alt) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.cmd) ? "⌘" : "")
    }

    /// Parses a modifier-only list such as "ctrl+alt". Empty string means no modifiers.
    static func parse(_ text: String) throws -> Modifiers {
        var mods: Modifiers = []
        for part in text.split(separator: "+") {
            let token = part.trimmingCharacters(in: .whitespaces)
            guard let mod = Modifiers.token(token) else { throw ConfigError("unknown modifier '\(token)'") }
            mods.formUnion(mod)
        }
        return mods
    }
}

struct KeyCombo: Equatable {
    /// Config text for a shortcut: "meh+1", "hyper+h", "ctrl+alt+left".
    static func text(_ mods: Modifiers, key: String) -> String {
        if mods == .hyper { return "hyper+\(key)" }
        if mods == [.ctrl, .alt, .shift] { return "meh+\(key)" }
        return mods.isEmpty ? key : "\(mods.configText)+\(key)"
    }

    /// "⌃⌥⇧ 1" for display.
    static func label(_ text: String) -> String {
        let tokens = text.split(separator: "+").map(String.init)
        guard let key = tokens.last else { return text }
        let mods = tokens.dropLast().reduce(into: Modifiers()) { $0.formUnion(Modifiers.token($1) ?? []) }
        return [mods.symbols, KeyInfo.label(for: key)].filter { !$0.isEmpty }.joined(separator: " ")
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    /// Parses "hyper+h", "cmd+shift+return", "cmd+-" (the last token is the key).
    static func parse(_ text: String) throws -> KeyCombo {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = tokens.last, !name.isEmpty, let key = KeyCodes.lookup(name) else {
            throw ConfigError("unknown key in '\(text)'")
        }
        guard let keyCode = key.keyCode else {
            throw ConfigError("'\(name)' can be remapped but not used in a shortcut")
        }
        var mods: Modifiers = []
        for token in tokens.dropLast() {
            guard let mod = Modifiers.token(token) else { throw ConfigError("unknown modifier '\(token)' in '\(text)'") }
            mods.formUnion(mod)
        }
        return KeyCombo(keyCode: keyCode, modifiers: mods)
    }
}
