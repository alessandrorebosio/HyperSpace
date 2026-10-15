/// AeroSpace's key notation for `[mode.*.binding]`, e.g. `ctrl-alt-shift-leftSquareBracket`,
/// mapped to HyperSpace's physical key names. Letters and symbols name US (qwerty) positions.
public enum WMKeys {
    /// AeroSpace notation -> KeyNames name.
    static let names: [String: String] = {
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

    /// Modifiers in AeroSpace bindings.
    static let modifiers: [String: Modifiers] = ["cmd": .command, "alt": .option, "ctrl": .control, "shift": .shift]

    /// Parses `ctrl-alt-shift-h`.
    static func combo(_ text: String, path: String) throws(InvalidConfig) -> Combo {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { throw InvalidConfig(message: "\(path): '\(text)' has no key") }
        var mods: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifiers[part] else {
                throw InvalidConfig(message: "\(path): unknown modifier '\(part)'; use cmd, alt, ctrl, shift")
            }
            mods.insert(modifier)
        }
        guard let name = names[keyName], let key = KeyNames.key(name) else {
            throw InvalidConfig(message: "\(path): unknown key '\(keyName)'")
        }
        return Combo(key: key, modifiers: mods)
    }
}
