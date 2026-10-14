/// A physical key: macOS virtual key code (what CGEvent carries) and HID usage on the
/// keyboard page 0x07 (what `UserKeyMapping` remaps).
public struct Key: Sendable, Hashable {
    public let code: UInt16
    public let usage: UInt32

    public var isModifier: Bool { (0xE0...0xE7).contains(usage) }

    /// Arrow keys carry the fn and numeric pad flags when typed on a real keyboard.
    public var isArrow: Bool { (123...126).contains(code) }

    /// Keys that macOS reports with the fn flag (function row, navigation block, arrows).
    public var hasFnFlag: Bool {
        isArrow || [115, 116, 117, 119, 121].contains(code) || Key.functionKeyCodes.contains(code)
    }

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                105, 107, 113, 106, 64, 79, 80, 90]
}

public enum KeyNames {
    /// Name -> key. Names follow Karabiner where it makes sense; a few short aliases are added.
    public static let table: [String: Key] = {
        var t: [String: Key] = [:]
        func add(_ names: [String], _ code: UInt16, _ usage: UInt32) {
            for name in names { t[name] = Key(code: code, usage: usage) }
        }

        let letters: [(String, UInt16)] = [
            ("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4), ("i", 34),
            ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31), ("p", 35), ("q", 12),
            ("r", 15), ("s", 1), ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6),
        ]
        for (i, (name, code)) in letters.enumerated() { add([name], code, 0x04 + UInt32(i)) }

        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1...9
        for (i, code) in digits.enumerated() { add(["\(i + 1)"], code, 0x1E + UInt32(i)) }
        add(["0"], 29, 0x27)

        add(["return_or_enter", "return", "enter"], 36, 0x28)
        add(["escape", "esc"], 53, 0x29)
        add(["delete_or_backspace", "backspace"], 51, 0x2A)
        add(["tab"], 48, 0x2B)
        add(["spacebar", "space"], 49, 0x2C)
        add(["hyphen", "minus"], 27, 0x2D)
        add(["equal_sign", "equal"], 24, 0x2E)
        add(["open_bracket"], 33, 0x2F)
        add(["close_bracket"], 30, 0x30)
        add(["backslash"], 42, 0x31)
        add(["semicolon"], 41, 0x33)
        add(["quote"], 39, 0x34)
        add(["grave_accent_and_tilde", "grave"], 50, 0x35)
        add(["comma"], 43, 0x36)
        add(["period"], 47, 0x37)
        add(["slash"], 44, 0x38)
        add(["caps_lock"], 57, 0x39)
        add(["non_us_backslash"], 10, 0x64)

        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fCodes.enumerated() { add(["f\(i + 1)"], code, 0x3A + UInt32(i)) }
        let fHighCodes: [UInt16] = [105, 107, 113, 106, 64, 79, 80, 90] // f13...f20
        for (i, code) in fHighCodes.enumerated() { add(["f\(i + 13)"], code, 0x68 + UInt32(i)) }

        add(["home"], 115, 0x4A)
        add(["page_up"], 116, 0x4B)
        add(["delete_forward"], 117, 0x4C)
        add(["end"], 119, 0x4D)
        add(["page_down"], 121, 0x4E)
        add(["right_arrow", "right"], 124, 0x4F)
        add(["left_arrow", "left"], 123, 0x50)
        add(["down_arrow", "down"], 125, 0x51)
        add(["up_arrow", "up"], 126, 0x52)
        add(["keypad_enter"], 76, 0x58)

        add(["left_control"], 59, 0xE0)
        add(["left_shift"], 56, 0xE1)
        add(["left_option"], 58, 0xE2)
        add(["left_command"], 55, 0xE3)
        add(["right_control"], 62, 0xE4)
        add(["right_shift"], 60, 0xE5)
        add(["right_option"], 61, 0xE6)
        add(["right_command"], 54, 0xE7)
        return t
    }()

    public static func key(_ name: String) -> Key? { table[name.lowercased()] }

    /// Reverse lookup by virtual key code. Array-backed: used on the input thread.
    public static func key(code: UInt16) -> Key? {
        code < 128 ? byCode[Int(code)] : nil
    }

    private static let byCode: [Key?] = {
        var keys = [Key?](repeating: nil, count: 128)
        for key in table.values where key.code < 128 { keys[Int(key.code)] = key }
        return keys
    }()
}
