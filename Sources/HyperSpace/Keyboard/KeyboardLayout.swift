import Carbon.HIToolbox

/// Key codes are physical positions (ANSI). Apps match shortcuts by character, so on
/// other layouts a symbol shortcut must use the key that types that symbol there:
/// ⌘- on an Italian keyboard is the key in the ANSI "/" position.
enum KeyboardLayout {
    /// ANSI symbol keys and the character a shortcut on them means.
    private static let symbols: [UInt16: Character] = [
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";",
        0x27: "'", 0x32: "`", 0x2B: ",", 0x2F: ".", 0x2C: "/",
    ]
    /// When a layout cannot type a symbol without modifiers, the equivalent apps accept.
    private static let alternatives: [Character: Character] = ["=": "+"]

    private static let keypad: Set<UInt16> = [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,
                                              0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]

    private static var layoutID: String?
    private static var keyCodes: [Character: UInt16] = [:]

    /// The key code that types the same symbol on the current layout (main thread only).
    static func keyCode(for ansiCode: UInt16) -> UInt16 {
        guard let symbol = symbols[ansiCode] else { return ansiCode }
        refresh()
        if let code = keyCodes[symbol] { return code }
        if let alternative = alternatives[symbol], let code = keyCodes[alternative] { return code }
        return ansiCode
    }

    /// Rebuilds the character → key code table when the input source changes.
    private static func refresh() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        let id = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        guard id != layoutID else { return }
        layoutID = id
        keyCodes = [:]

        guard let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return }
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars
                )
                // Keypad keys type the same symbols but many apps don't treat them as shortcuts.
                guard status == noErr, length == 1, !keypad.contains(code), let scalar = Unicode.Scalar(chars[0]) else { continue }
                let character = Character(scalar)
                if keyCodes[character] == nil { keyCodes[character] = code }
            }
        }
    }
}
