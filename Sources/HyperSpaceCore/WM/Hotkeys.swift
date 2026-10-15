/// Global hotkeys (wm.toml `[mode.<name>.binding]`), compiled into one flat table per mode
/// that the tap indexes directly: no hashing or allocation per key press.
public enum Hotkeys {
    /// ⌘⇧⌥⌃ (fn and caps lock don't count) and the key code.
    @inline(__always)
    public static func index(code: UInt16, modifiers: Modifiers) -> Int {
        Int(modifiers.rawValue & 0x0F) << 7 | Int(code & 0x7F)
    }
}
