import Foundation

/// What a remapped key produces.
///
/// - A single key is remapped 1:1 in the HID layer.
/// - A combination ("shift+ctrl+alt", "hyper", "cmd+space") cannot be expressed in HID,
///   so the source key is remapped to an unused carrier key (F13–F20) and the event tap
///   turns the carrier into the combination: modifiers are held while it is down, and
///   a key, if any, is pressed together with them.
enum RemapTarget: Equatable {
    case key(UInt64)
    case combination(Modifiers, keyCode: UInt16?, keyName: String?)

    static func parse(_ text: String) throws -> RemapTarget {
        let tokens = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { throw ConfigError("empty remap target") }

        if tokens.count == 1, let hid = KeyCodes.lookup(tokens[0])?.hidUsage {
            return .key(hid)
        }
        var mods: Modifiers = []
        var keyCode: UInt16?
        var keyName: String?
        for token in tokens {
            if let mod = Modifiers.token(token) ?? Modifiers.modifierKey(token) {
                mods.formUnion(mod)
                continue
            }
            guard keyCode == nil else { throw ConfigError("'\(text)': a combination can contain only one non-modifier key") }
            guard let key = KeyCodes.lookup(token) else { throw ConfigError("unknown key '\(token)' in '\(text)'") }
            guard let code = key.keyCode else { throw ConfigError("'\(token)' cannot be part of a combination") }
            keyCode = code
            keyName = token
        }
        // A lone generic modifier ("shift") is just the left modifier key, done in HID.
        if keyCode == nil, let single = singleModifierKey(mods), let hid = KeyCodes.lookup(single)?.hidUsage {
            return .key(hid)
        }
        return .combination(mods, keyCode: keyCode, keyName: keyName)
    }

    private static func singleModifierKey(_ mods: Modifiers) -> String? {
        switch mods {
        case .cmd: return "left_command"
        case .alt: return "left_option"
        case .ctrl: return "left_control"
        case .shift: return "left_shift"
        default: return nil
        }
    }

    /// Canonical config text for a combination: "hyper", "meh" or "ctrl+alt+shift+cmd+key".
    static func text(_ mods: Modifiers, key: String?) -> String {
        if key == nil && mods == .hyper { return "hyper" }
        if key == nil && mods == [.alt, .ctrl, .shift] { return "meh" }
        var parts: [String] = []
        if mods.contains(.ctrl) { parts.append("ctrl") }
        if mods.contains(.alt) { parts.append("alt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.cmd) { parts.append("cmd") }
        if let key { parts.append(key) }
        return parts.joined(separator: "+")
    }

    /// Human label: "Escape", "Hyper ⌃⌥⇧⌘", "⌃⌥⇧", "⌘ Space".
    static func label(_ text: String) -> String {
        switch try? parse(text) {
        case .combination(let mods, _, let keyName):
            let keyLabel = keyName.map { KeyInfo.label(for: $0) }
            if keyLabel == nil && mods == .hyper { return "Hyper  ⌃⌥⇧⌘" }
            if keyLabel == nil && mods == [.alt, .ctrl, .shift] { return "Meh  ⌃⌥⇧" }
            return [mods.symbols, keyLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        default:
            return KeyInfo.label(for: text)
        }
    }
}

/// Hands out carrier keys for combinations, skipping any key the config uses itself.
struct CarrierPool {
    private static let candidates = ["f20", "f19", "f18", "f17", "f16", "f15", "f14", "f13"]
    private var free: [Key]
    private var assigned: [String: Key] = [:]

    init(excludingHID usedHID: Set<UInt64>, keyCodes usedCodes: Set<UInt16>) {
        free = Self.candidates.compactMap { KeyCodes.lookup($0) }.filter { key in
            !usedHID.contains(key.hidUsage!) && !usedCodes.contains(key.keyCode!)
        }
    }

    /// The same combination always shares one carrier.
    mutating func carrier(for id: String) throws -> (key: Key, isNew: Bool) {
        if let key = assigned[id] { return (key, false) }
        guard !free.isEmpty else { throw ConfigError("too many different combinations (at most 8)") }
        let key = free.removeFirst()
        assigned[id] = key
        return (key, true)
    }
}
