/// A physical key: macOS virtual key code (what CGEvent carries) and HID usage on the
/// keyboard page 0x07 (what `UserKeyMapping` remaps).
public struct Key: Sendable, Hashable {
    public let code: UInt16
    public let usage: UInt32
    /// macOS reports these keys with the fn flag (function row, navigation block, arrows).
    public var hasFnFlag = false

    public var isModifier: Bool { (0xE0...0xE7).contains(usage) }

    /// Arrow keys also carry the numeric pad flag when typed on a real keyboard.
    public var isArrow: Bool { (123...126).contains(code) }
}

public enum KeyNames {
    /// Name -> key. Multi-word names are `family.variant` (`arrow.left`, `command.right`, `page.up`).
    public static let table: [String: Key] = {
        var t: [String: Key] = [:]
        func add(_ names: [String], _ code: UInt16, _ usage: UInt32, fn: Bool = false) {
            for name in names { t[name] = Key(code: code, usage: usage, hasFnFlag: fn) }
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

        add(["return", "enter"], 36, 0x28)
        add(["escape", "esc"], 53, 0x29)
        add(["backspace"], 51, 0x2A)
        add(["tab"], 48, 0x2B)
        add(["space"], 49, 0x2C)
        add(["minus"], 27, 0x2D)
        add(["equal"], 24, 0x2E)
        add(["bracket.open"], 33, 0x2F)
        add(["bracket.close"], 30, 0x30)
        add(["backslash"], 42, 0x31)
        add(["semicolon"], 41, 0x33)
        add(["quote"], 39, 0x34)
        add(["grave"], 50, 0x35)
        add(["comma"], 43, 0x36)
        add(["period"], 47, 0x37)
        add(["slash"], 44, 0x38)
        add(["capslock"], 57, 0x39)
        add(["backslash.iso"], 10, 0x64) // the extra key next to left shift on ISO keyboards

        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fCodes.enumerated() { add(["f\(i + 1)"], code, 0x3A + UInt32(i), fn: true) }
        let fHighCodes: [UInt16] = [105, 107, 113, 106, 64, 79, 80, 90] // f13...f20
        for (i, code) in fHighCodes.enumerated() { add(["f\(i + 13)"], code, 0x68 + UInt32(i), fn: true) }

        add(["home"], 115, 0x4A, fn: true)
        add(["page.up"], 116, 0x4B, fn: true)
        add(["delete.forward"], 117, 0x4C, fn: true)
        add(["end"], 119, 0x4D, fn: true)
        add(["page.down"], 121, 0x4E, fn: true)
        add(["arrow.right"], 124, 0x4F, fn: true)
        add(["arrow.left"], 123, 0x50, fn: true)
        add(["arrow.down"], 125, 0x51, fn: true)
        add(["arrow.up"], 126, 0x52, fn: true)
        add(["keypad.enter"], 76, 0x58)

        add(["control.left"], 59, 0xE0)
        add(["shift.left"], 56, 0xE1)
        add(["option.left"], 58, 0xE2)
        add(["command.left"], 55, 0xE3)
        add(["control.right"], 62, 0xE4)
        add(["shift.right"], 60, 0xE5)
        add(["option.right"], 61, 0xE6)
        add(["command.right"], 54, 0xE7)
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
