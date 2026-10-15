/// AeroSpace's key notation for `[mode.*.binding]`, e.g. `ctrl-alt-shift-leftSquareBracket`,
/// mapped to HyperSpace's physical key names. Letters and symbols name US (qwerty) positions,
/// unless `key-mapping.preset` says the user types on dvorak or colemak.
public enum WMKeys {
    /// AeroSpace notation -> KeyNames name, for qwerty.
    static let qwerty: [String: String] = {
        var map: [String: String] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz0123456789" { map[String(c)] = String(c) }
        for i in 0...9 { map["keypad\(i)"] = "keypad.\(i)" }
        for i in 1...20 { map["f\(i)"] = "f\(i)" }
        let named: [String: String] = [
            "keypadClear": "keypad.clear", "keypadDecimalMark": "keypad.decimal", "keypadDivide": "keypad.divide",
            "keypadEnter": "keypad.enter", "keypadEqual": "keypad.equal", "keypadMinus": "keypad.minus",
            "keypadMultiply": "keypad.multiply", "keypadPlus": "keypad.plus",
            "pageUp": "page.up", "pageDown": "page.down", "home": "home", "end": "end", "forwardDelete": "delete.forward",
            "backtick": "grave", "space": "space", "enter": "return", "esc": "escape", "backspace": "backspace", "tab": "tab",
            "left": "arrow.left", "down": "arrow.down", "up": "arrow.up", "right": "arrow.right",
            "minus": "minus", "equal": "equal", "period": "period", "comma": "comma", "slash": "slash",
            "backslash": "backslash", "quote": "quote", "semicolon": "semicolon",
            "leftSquareBracket": "bracket.open", "rightSquareBracket": "bracket.close", "sectionSign": "backslash.iso",
        ]
        map.merge(named) { $1 }
        return map
    }()

    /// Where each notation sits on a qwerty keyboard when typing on another layout.
    static let presets: [String: [String: String]] = [
        "qwerty": [:],
        "dvorak": [
            "leftSquareBracket": "minus", "rightSquareBracket": "equal", "quote": "q", "comma": "w", "period": "e",
            "p": "r", "y": "t", "f": "y", "g": "u", "c": "i", "r": "o", "l": "p", "slash": "bracket.open",
            "equal": "bracket.close", "a": "a", "o": "s", "e": "d", "u": "f", "i": "g", "d": "h", "h": "j", "t": "k",
            "n": "l", "s": "semicolon", "minus": "quote", "semicolon": "z", "q": "x", "j": "c", "k": "v", "x": "b",
            "b": "n", "m": "m", "w": "comma", "v": "period", "z": "slash",
        ],
        "colemak": [
            "f": "e", "p": "r", "g": "t", "j": "y", "l": "u", "u": "i", "y": "o", "semicolon": "p", "r": "s", "s": "d",
            "t": "f", "d": "g", "n": "j", "e": "k", "i": "l", "o": "semicolon", "k": "n",
        ],
    ]

    /// Modifiers in AeroSpace bindings.
    static let modifiers: [String: Modifiers] = ["cmd": .command, "alt": .option, "ctrl": .control, "shift": .shift]

    /// Parses `ctrl-alt-shift-h` with the config's key mapping.
    static func combo(_ text: String, preset: String, notation: [String: String], path: String) throws(InvalidConfig) -> Combo {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { throw InvalidConfig(message: "\(path): '\(text)' has no key") }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifiers[part] else {
                throw InvalidConfig(message: "\(path): unknown modifier '\(part)'; use cmd, alt, ctrl, shift")
            }
            mods.insert(modifier)
        }
        // key-notation-to-key-code can rename keys; it maps to a notation of the preset.
        let notationKey = notation[keyName] ?? keyName
        guard let name = presets[preset]?[notationKey] ?? qwerty[notationKey], let key = KeyNames.key(name) else {
            throw InvalidConfig(message: "\(path): unknown key '\(keyName)'")
        }
        return Combo(key: key, modifiers: mods)
    }
}
