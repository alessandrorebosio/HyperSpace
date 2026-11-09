import AppKit

struct Modifiers: OptionSet, Hashable {
    let rawValue: UInt8

    static let cmd = Modifiers(rawValue: 1 << 0)
    static let alt = Modifiers(rawValue: 1 << 1)
    static let ctrl = Modifiers(rawValue: 1 << 2)
    static let shift = Modifiers(rawValue: 1 << 3)
    static let hyper: Modifiers = [.cmd, .alt, .ctrl, .shift]
    static let meh: Modifiers = [.alt, .ctrl, .shift]

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Each modifier with its flag in a CGEvent and in an NSEvent: the one table both conversions read.
    private static let flagTable: [(modifier: Modifiers, cg: CGEventFlags, ns: NSEvent.ModifierFlags)] = [
        (.cmd, .maskCommand, .command),
        (.alt, .maskAlternate, .option),
        (.ctrl, .maskControl, .control),
        (.shift, .maskShift, .shift),
    ]

    init(_ flags: CGEventFlags) {
        var mods: Modifiers = []
        for entry in Modifiers.flagTable where flags.contains(entry.cg) { mods.insert(entry.modifier) }
        self = mods
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var mods: Modifiers = []
        for entry in Modifiers.flagTable where flags.contains(entry.ns) { mods.insert(entry.modifier) }
        self = mods
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for entry in Modifiers.flagTable where contains(entry.modifier) { flags.insert(entry.cg) }
        return flags
    }

    static func token(_ token: String) -> Modifiers? {
        switch token.lowercased() {
        case "cmd", "command", "⌘": return .cmd
        case "alt", "opt", "option", "⌥": return .alt
        case "ctrl", "control", "⌃": return .ctrl
        case "shift", "⇧": return .shift
        case "hyper": return .hyper
        case "meh": return .meh
        default: return nil
        }
    }

    /// The modifier a physical modifier key produces ("left_shift" → .shift), by any of its names.
    static func modifierKey(_ name: String) -> Modifiers? {
        KeyCodes.lookup(name)?.keyCode.flatMap { KeyCodes.modifierKeyCodes[$0] }
    }

    /// What a token of a combination stands for: a modifier ("cmd", "hyper") and, with `keys`,
    /// a physical modifier key too ("left_shift").
    static func named(_ token: String, keys: Bool = false) -> Modifiers? {
        Modifiers.token(token) ?? (keys ? modifierKey(token) : nil)
    }

    /// The union of the modifiers `tokens` name; `unknown` makes the error for the first that is none.
    static func parse<Tokens: Sequence>(tokens: Tokens, unknown: (String) -> ConfigError) throws -> Modifiers
        where Tokens.Element == String {
        var mods: Modifiers = []
        for token in tokens {
            guard let mod = named(token) else { throw unknown(token) }
            mods.formUnion(mod)
        }
        return mods
    }

    /// Config text, e.g. "ctrl+alt".
    var configText: String {
        [(Modifiers.ctrl, "ctrl"), (.alt, "alt"), (.shift, "shift"), (.cmd, "cmd")]
            .filter { contains($0.0) }.map(\.1).joined(separator: "+")
    }

    /// Config text for these modifiers plus an optional key: "hyper", "meh+1",
    /// "ctrl+alt+left", "cmd+space".
    func text(key: String?) -> String {
        let prefix = self == .hyper ? "hyper" : self == .meh ? "meh" : configText
        guard let key else { return prefix }
        return prefix.isEmpty ? key : "\(prefix)+\(key)"
    }

    /// ⌃⌥⇧⌘ in macOS menu order.
    var symbols: String {
        (contains(.ctrl) ? "⌃" : "") + (contains(.alt) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.cmd) ? "⌘" : "")
    }

    /// Parses a modifier-only list such as "ctrl+alt". Empty string means no modifiers.
    static func parse(_ text: String) throws -> Modifiers {
        let tokens = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        return try parse(tokens: tokens) { ConfigError("unknown modifier '\($0)'") }
    }
}

struct KeyCombo: Equatable {
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
        let mods = try Modifiers.parse(tokens: tokens.dropLast()) { ConfigError("unknown modifier '\($0)' in '\(text)'") }
        return KeyCombo(keyCode: keyCode, modifiers: mods)
    }
}
