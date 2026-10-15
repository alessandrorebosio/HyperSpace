/// Global hotkeys (wm.toml `[bindings]`), compiled into one flat table the tap can index
/// directly: no hashing or allocation per key press.
public enum Hotkeys {
    /// ⌘⇧⌥⌃ (fn and caps lock don't count) and the key code.
    @inline(__always)
    public static func index(code: UInt16, modifiers: Modifiers) -> Int {
        Int(modifiers.rawValue & 0x0F) << 7 | Int(code & 0x7F)
    }

    /// `[bindings]` -> table. Each binding runs its commands in order.
    public static func compile(_ config: WMConfig) throws(InvalidConfig) -> OutputTable {
        var table = OutputTable.hotkeys
        guard config.enabled else { return table }
        for (hotkey, commands) in config.bindings.sorted(by: { $0.key < $1.key }) {
            let path = "bindings.\(hotkey)"
            let combo = try Compile.combo(hotkey, path: path)
            guard !combo.key.isModifier else { throw InvalidConfig(message: "\(path): a hotkey needs a non-modifier key") }
            guard !commands.isEmpty else { throw InvalidConfig(message: "\(path): no command") }
            var outputs: [Output] = []
            for command in commands {
                do {
                    _ = try WMCommand(parsing: command)
                } catch {
                    throw InvalidConfig(message: "\(path): \(error.message)")
                }
                outputs.append(.wm(command))
            }
            table[index(code: combo.key.code, modifiers: combo.modifiers)] = outputs.count == 1 ? outputs[0] : .sequence(outputs)
        }
        return table
    }
}
