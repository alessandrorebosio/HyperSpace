public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
    public static let fn = Modifiers(rawValue: 1 << 4)

    static let names: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "opt": .option, "option": .option, "alt": .option,
        "ctrl": .control, "control": .control,
        "fn": .fn,
    ]
}

/// A key plus modifiers, e.g. `cmd-shift-k`, `ctrl-minus`, `left_arrow`.
public struct Combo: Sendable, Hashable {
    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Returns nil if a part isn't a known modifier or key.
    public init?(parsing text: String) {
        var parts = text.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.popLast(), let key = KeyNames.key(keyName) else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            guard let modifier = Modifiers.names[part] else { return nil }
            modifiers.insert(modifier)
        }
        self.init(key: key, modifiers: modifiers)
    }
}
