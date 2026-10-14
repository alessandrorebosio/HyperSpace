/// What a remapped key or mouse button produces.
public enum Output: Sendable, Equatable {
    /// Swallow the input.
    case drop
    /// A key code with modifiers. Key names refer to physical positions (US layout).
    case key(Combo)
    /// Back/forward in the app under the input, independent of the keyboard layout.
    case navigate(Navigation)
    case shell(String)
    case wm(String)
}

public enum Navigation: Sendable, Equatable {
    case back, forward
}

/// Lookup table indexed by key code or button number. `nil` = not remapped: normal behavior.
public struct OutputTable: Sendable, Equatable {
    private var outputs: [Output?]

    public static var keys: OutputTable { OutputTable(count: 128) }
    public static var buttons: OutputTable { OutputTable(count: 32) }

    private init(count: Int) {
        outputs = [Output?](repeating: nil, count: count)
    }

    public subscript(index: Int) -> Output? {
        get { outputs.indices.contains(index) ? outputs[index] : nil }
        set { if outputs.indices.contains(index) { outputs[index] = newValue } }
    }

    public var isEmpty: Bool { outputs.allSatisfy { $0 == nil } }
}

/// A config value that can't be applied. `ConfigLoader` adds the file path.
public struct InvalidConfig: Error, Equatable {
    public let message: String
}

/// Validation helpers shared by the keyboard and mouse plans.
enum Compile {
    private static let dotsHint = " (multi-word names use dots, e.g. arrow.left)"

    static func key(_ name: String, path: String) throws(InvalidConfig) -> Key {
        guard let key = KeyNames.key(name) else {
            throw InvalidConfig(message: "\(path): unknown key '\(name)'\(name.contains("_") ? dotsHint : "")")
        }
        return key
    }

    static func combo(_ text: String, path: String) throws(InvalidConfig) -> Combo {
        guard let combo = Combo(parsing: text) else {
            throw InvalidConfig(message: "\(path): unknown key or combo '\(text)'\(text.contains("_") ? dotsHint : "")")
        }
        return combo
    }

    /// `nil` means passthrough.
    static func output(_ action: Action, path: String) throws(InvalidConfig) -> Output? {
        switch action {
        case .none: .drop
        case .passthrough: nil
        case let .shell(command): .shell(command)
        case let .wm(command): .wm(command)
        case .keys("navigate.back"): .navigate(.back)
        case .keys("navigate.forward"): .navigate(.forward)
        case let .keys(text): .key(try combo(text, path: path))
        }
    }
}
