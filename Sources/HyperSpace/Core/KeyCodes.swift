import CoreGraphics
import Foundation

/// A physical key: its macOS virtual key code (what event taps see, used by
/// bindings) and its full HID usage, `page << 32 | usage` (used by remapping).
/// Keys that macOS never turns into key events (media keys, F21–F24) have no key code.
struct Key {
    let keyCode: UInt16?
    let hidUsage: UInt64?
}

enum KeyCodes {
    /// F18 is the carrier for the hyper key: the hyper key is remapped to it at HID level,
    /// then the event tap turns it into cmd+alt+ctrl+shift while held.
    static let f18: UInt16 = 0x4F
    static let f18HID: UInt64 = keyboard(0x6D)

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

    private static let table: [String: Key] = {
        var table: [String: Key] = [:]
        let entries: [([String], UInt16?, UInt64)] = [
            // Letters and digits
            (["a"], 0x00, keyboard(0x04)), (["b"], 0x0B, keyboard(0x05)), (["c"], 0x08, keyboard(0x06)),
            (["d"], 0x02, keyboard(0x07)), (["e"], 0x0E, keyboard(0x08)), (["f"], 0x03, keyboard(0x09)),
            (["g"], 0x05, keyboard(0x0A)), (["h"], 0x04, keyboard(0x0B)), (["i"], 0x22, keyboard(0x0C)),
            (["j"], 0x26, keyboard(0x0D)), (["k"], 0x28, keyboard(0x0E)), (["l"], 0x25, keyboard(0x0F)),
            (["m"], 0x2E, keyboard(0x10)), (["n"], 0x2D, keyboard(0x11)), (["o"], 0x1F, keyboard(0x12)),
            (["p"], 0x23, keyboard(0x13)), (["q"], 0x0C, keyboard(0x14)), (["r"], 0x0F, keyboard(0x15)),
            (["s"], 0x01, keyboard(0x16)), (["t"], 0x11, keyboard(0x17)), (["u"], 0x20, keyboard(0x18)),
            (["v"], 0x09, keyboard(0x19)), (["w"], 0x0D, keyboard(0x1A)), (["x"], 0x07, keyboard(0x1B)),
            (["y"], 0x10, keyboard(0x1C)), (["z"], 0x06, keyboard(0x1D)),
            (["1"], 0x12, keyboard(0x1E)), (["2"], 0x13, keyboard(0x1F)), (["3"], 0x14, keyboard(0x20)),
            (["4"], 0x15, keyboard(0x21)), (["5"], 0x17, keyboard(0x22)), (["6"], 0x16, keyboard(0x23)),
            (["7"], 0x1A, keyboard(0x24)), (["8"], 0x1C, keyboard(0x25)), (["9"], 0x19, keyboard(0x26)),
            (["0"], 0x1D, keyboard(0x27)),

            // Editing and whitespace
            (["return", "enter"], 0x24, keyboard(0x28)),
            (["escape", "esc"], 0x35, keyboard(0x29)),
            (["delete", "backspace"], 0x33, keyboard(0x2A)),
            (["tab"], 0x30, keyboard(0x2B)),
            (["space"], 0x31, keyboard(0x2C)),
            (["forward_delete"], 0x75, keyboard(0x4C)),
            (["insert", "help"], 0x72, keyboard(0x49)),
            (["application", "menu"], 0x6E, keyboard(0x65)),

            // Punctuation (ANSI positions)
            (["minus", "-"], 0x1B, keyboard(0x2D)),
            (["equal", "="], 0x18, keyboard(0x2E)),
            (["left_bracket", "["], 0x21, keyboard(0x2F)),
            (["right_bracket", "]"], 0x1E, keyboard(0x30)),
            (["backslash", "\\"], 0x2A, keyboard(0x31)),
            (["non_us_pound"], 0x2A, keyboard(0x32)),
            (["semicolon", ";"], 0x29, keyboard(0x33)),
            (["quote", "'"], 0x27, keyboard(0x34)),
            (["grave", "`"], 0x32, keyboard(0x35)),
            (["comma", ","], 0x2B, keyboard(0x36)),
            (["period", "."], 0x2F, keyboard(0x37)),
            (["slash", "/"], 0x2C, keyboard(0x38)),
            (["section", "§", "non_us_backslash"], 0x0A, keyboard(0x64)),

            // Navigation
            (["home"], 0x73, keyboard(0x4A)),
            (["page_up"], 0x74, keyboard(0x4B)),
            (["end"], 0x77, keyboard(0x4D)),
            (["page_down"], 0x79, keyboard(0x4E)),
            (["right"], 0x7C, keyboard(0x4F)),
            (["left"], 0x7B, keyboard(0x50)),
            (["down"], 0x7D, keyboard(0x51)),
            (["up"], 0x7E, keyboard(0x52)),

            // Locks and PC keys (macOS reports print/scroll/pause as F13/F14/F15)
            (["caps_lock"], 0x39, keyboard(0x39)),
            (["print_screen"], 0x69, keyboard(0x46)),
            (["scroll_lock"], 0x6B, keyboard(0x47)),
            (["pause"], 0x71, keyboard(0x48)),

            // Modifiers
            (["left_control"], 0x3B, keyboard(0xE0)),
            (["left_shift"], 0x38, keyboard(0xE1)),
            (["left_option", "left_alt"], 0x3A, keyboard(0xE2)),
            (["left_command", "left_cmd"], 0x37, keyboard(0xE3)),
            (["right_control"], 0x3E, keyboard(0xE4)),
            (["right_shift"], 0x3C, keyboard(0xE5)),
            (["right_option", "right_alt"], 0x3D, keyboard(0xE6)),
            (["right_command", "right_cmd"], 0x36, keyboard(0xE7)),
            // Apple fn / 🌐 key (Apple keyboards only; most PC keyboards handle fn in firmware)
            (["fn", "globe"], 0x3F, 0xFF << 32 | 0x03),

            // Function keys
            (["f1"], 0x7A, keyboard(0x3A)), (["f2"], 0x78, keyboard(0x3B)), (["f3"], 0x63, keyboard(0x3C)),
            (["f4"], 0x76, keyboard(0x3D)), (["f5"], 0x60, keyboard(0x3E)), (["f6"], 0x61, keyboard(0x3F)),
            (["f7"], 0x62, keyboard(0x40)), (["f8"], 0x64, keyboard(0x41)), (["f9"], 0x65, keyboard(0x42)),
            (["f10"], 0x6D, keyboard(0x43)), (["f11"], 0x67, keyboard(0x44)), (["f12"], 0x6F, keyboard(0x45)),
            (["f13"], 0x69, keyboard(0x68)), (["f14"], 0x6B, keyboard(0x69)), (["f15"], 0x71, keyboard(0x6A)),
            (["f16"], 0x6A, keyboard(0x6B)), (["f17"], 0x40, keyboard(0x6C)), (["f18"], 0x4F, keyboard(0x6D)),
            (["f19"], 0x50, keyboard(0x6E)), (["f20"], 0x5A, keyboard(0x6F)),
            (["f21"], nil, keyboard(0x70)), (["f22"], nil, keyboard(0x71)),
            (["f23"], nil, keyboard(0x72)), (["f24"], nil, keyboard(0x73)),

            // Keypad
            (["keypad_0"], 0x52, keyboard(0x62)), (["keypad_1"], 0x53, keyboard(0x59)),
            (["keypad_2"], 0x54, keyboard(0x5A)), (["keypad_3"], 0x55, keyboard(0x5B)),
            (["keypad_4"], 0x56, keyboard(0x5C)), (["keypad_5"], 0x57, keyboard(0x5D)),
            (["keypad_6"], 0x58, keyboard(0x5E)), (["keypad_7"], 0x59, keyboard(0x5F)),
            (["keypad_8"], 0x5B, keyboard(0x60)), (["keypad_9"], 0x5C, keyboard(0x61)),
            (["keypad_period"], 0x41, keyboard(0x63)),
            (["keypad_enter"], 0x4C, keyboard(0x58)),
            (["keypad_plus"], 0x45, keyboard(0x57)),
            (["keypad_minus"], 0x4E, keyboard(0x56)),
            (["keypad_multiply"], 0x43, keyboard(0x55)),
            (["keypad_divide"], 0x4B, keyboard(0x54)),
            (["keypad_equal"], 0x51, keyboard(0x67)),
            (["keypad_comma"], 0x5F, keyboard(0x85)),
            (["keypad_clear", "num_lock"], 0x47, keyboard(0x53)),

            // International (JIS / ISO)
            (["international1", "jis_underscore"], 0x5E, keyboard(0x87)),
            (["international3", "jis_yen"], 0x5D, keyboard(0x89)),
            (["lang1", "kana"], 0x68, keyboard(0x90)),
            (["lang2", "eisu"], 0x66, keyboard(0x91)),

            // Media (consumer page): remap only, macOS delivers them as system events
            (["mute"], nil, consumer(0xE2)),
            (["volume_up"], nil, consumer(0xE9)),
            (["volume_down"], nil, consumer(0xEA)),
            (["play_pause"], nil, consumer(0xCD)),
            (["next_track"], nil, consumer(0xB5)),
            (["previous_track"], nil, consumer(0xB6)),
            (["eject"], nil, consumer(0xB8)),
            (["brightness_up"], nil, consumer(0x6F)),
            (["brightness_down"], nil, consumer(0x70)),

            // Remap target that produces nothing: disables the source key.
            (["none", "disabled"], nil, keyboard(0x00)),
        ]
        for (names, code, hid) in entries {
            for name in names { table[name] = Key(keyCode: code, hidUsage: hid) }
        }
        return table
    }()
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

struct KeyCombo {
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
