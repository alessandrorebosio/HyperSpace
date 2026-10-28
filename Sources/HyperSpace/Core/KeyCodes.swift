import CoreGraphics

/// A physical key: its macOS virtual key code (for event taps) and its
/// HID usage on the keyboard page 0x07 (for `hidutil` remapping).
struct Key {
    let keyCode: UInt16
    let hidUsage: UInt16?
}

enum KeyCodes {
    /// F18 is the carrier for the hyper key: the hyper key is remapped to it at HID level,
    /// then the event tap turns it into cmd+alt+ctrl+shift while held.
    static let f18: UInt16 = 0x4F
    static let f18HID: UInt16 = 0x6D

    static func lookup(_ name: String) -> Key? {
        table[name.lowercased()]
    }

    private static let table: [String: Key] = {
        var table: [String: Key] = [:]
        let entries: [([String], UInt16, UInt16?)] = [
            (["a"], 0x00, 0x04), (["b"], 0x0B, 0x05), (["c"], 0x08, 0x06), (["d"], 0x02, 0x07),
            (["e"], 0x0E, 0x08), (["f"], 0x03, 0x09), (["g"], 0x05, 0x0A), (["h"], 0x04, 0x0B),
            (["i"], 0x22, 0x0C), (["j"], 0x26, 0x0D), (["k"], 0x28, 0x0E), (["l"], 0x25, 0x0F),
            (["m"], 0x2E, 0x10), (["n"], 0x2D, 0x11), (["o"], 0x1F, 0x12), (["p"], 0x23, 0x13),
            (["q"], 0x0C, 0x14), (["r"], 0x0F, 0x15), (["s"], 0x01, 0x16), (["t"], 0x11, 0x17),
            (["u"], 0x20, 0x18), (["v"], 0x09, 0x19), (["w"], 0x0D, 0x1A), (["x"], 0x07, 0x1B),
            (["y"], 0x10, 0x1C), (["z"], 0x06, 0x1D),
            (["1"], 0x12, 0x1E), (["2"], 0x13, 0x1F), (["3"], 0x14, 0x20), (["4"], 0x15, 0x21),
            (["5"], 0x17, 0x22), (["6"], 0x16, 0x23), (["7"], 0x1A, 0x24), (["8"], 0x1C, 0x25),
            (["9"], 0x19, 0x26), (["0"], 0x1D, 0x27),
            (["return", "enter"], 0x24, 0x28),
            (["escape", "esc"], 0x35, 0x29),
            (["delete", "backspace"], 0x33, 0x2A),
            (["tab"], 0x30, 0x2B),
            (["space"], 0x31, 0x2C),
            (["minus", "-"], 0x1B, 0x2D),
            (["equal", "="], 0x18, 0x2E),
            (["left_bracket", "["], 0x21, 0x2F),
            (["right_bracket", "]"], 0x1E, 0x30),
            (["backslash", "\\"], 0x2A, 0x31),
            (["semicolon", ";"], 0x29, 0x33),
            (["quote", "'"], 0x27, 0x34),
            (["grave", "`"], 0x32, 0x35),
            (["comma", ","], 0x2B, 0x36),
            (["period", "."], 0x2F, 0x37),
            (["slash", "/"], 0x2C, 0x38),
            (["caps_lock"], 0x39, 0x39),
            (["section", "§"], 0x0A, 0x64),
            (["forward_delete"], 0x75, 0x4C),
            (["home"], 0x73, 0x4A),
            (["page_up"], 0x74, 0x4B),
            (["end"], 0x77, 0x4D),
            (["page_down"], 0x79, 0x4E),
            (["right"], 0x7C, 0x4F),
            (["left"], 0x7B, 0x50),
            (["down"], 0x7D, 0x51),
            (["up"], 0x7E, 0x52),
            (["left_control"], 0x3B, 0xE0),
            (["left_shift"], 0x38, 0xE1),
            (["left_option"], 0x3A, 0xE2),
            (["left_command"], 0x37, 0xE3),
            (["right_control"], 0x3E, 0xE4),
            (["right_shift"], 0x3C, 0xE5),
            (["right_option"], 0x3D, 0xE6),
            (["right_command"], 0x36, 0xE7),
            (["f1"], 0x7A, 0x3A), (["f2"], 0x78, 0x3B), (["f3"], 0x63, 0x3C), (["f4"], 0x76, 0x3D),
            (["f5"], 0x60, 0x3E), (["f6"], 0x61, 0x3F), (["f7"], 0x62, 0x40), (["f8"], 0x64, 0x41),
            (["f9"], 0x65, 0x42), (["f10"], 0x6D, 0x43), (["f11"], 0x67, 0x44), (["f12"], 0x6F, 0x45),
            (["f13"], 0x69, 0x68), (["f14"], 0x6B, 0x69), (["f15"], 0x71, 0x6A), (["f16"], 0x6A, 0x6B),
            (["f17"], 0x40, 0x6C), (["f18"], 0x4F, 0x6D), (["f19"], 0x50, 0x6E), (["f20"], 0x5A, 0x6F),
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
        var mods: Modifiers = []
        for token in tokens.dropLast() {
            guard let mod = Modifiers.token(token) else { throw ConfigError("unknown modifier '\(token)' in '\(text)'") }
            mods.formUnion(mod)
        }
        return KeyCombo(keyCode: key.keyCode, modifiers: mods)
    }
}
