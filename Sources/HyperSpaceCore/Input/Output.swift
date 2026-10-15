/// What a remapped key or mouse button produces.
public enum Output: Sendable, Equatable {
    /// Swallow the input.
    case drop
    /// A key code with modifiers. Key names refer to physical positions (US layout).
    case key(Combo)
    /// Back/forward in the app under the input, independent of the keyboard layout.
    case navigate(Navigation)
    /// A keyboard media key: volume, brightness, playback.
    case media(MediaKey)
    case shell(String)
    case wm(String)
}

public enum Navigation: Sendable, Equatable {
    case back, forward
}

/// Media keys, as named in the config. Raw values are the `NX_KEYTYPE_*` codes the
/// system-defined event carries. Playback goes to the app that is playing (Spotify, Music...).
public enum MediaKey: Int, Sendable, CaseIterable {
    case volumeUp = 0, volumeDown = 1, volumeMute = 7
    case brightnessUp = 2, brightnessDown = 3
    case play = 16, next = 17, previous = 18

    public var name: String {
        switch self {
        case .volumeUp: "volume.up"
        case .volumeDown: "volume.down"
        case .volumeMute: "volume.mute"
        case .brightnessUp: "brightness.up"
        case .brightnessDown: "brightness.down"
        case .play: "media.play"
        case .next: "media.next"
        case .previous: "media.previous"
        }
    }

    static let byName = Dictionary(uniqueKeysWithValues: allCases.map { ($0.name, $0) })
}

/// Which apps get back/forward as a trackpad swipe rather than mouse buttons 4/5.
public struct NavigationRules: Sendable, Equatable {
    /// Apps known to handle navigation swipes but not mouse buttons 4/5.
    static let defaultSwipe = ["com.apple.", "org.mozilla.firefox", "com.operasoftware.Opera", "com.binarynights.ForkLift"]

    public var swipe = defaultSwipe
    public var buttons: [String] = []

    public init() {}

    init(_ config: NavigateConfig) {
        swipe = NavigationRules.defaultSwipe + config.swipe
        buttons = config.buttons
    }

    /// Bundle id prefixes: `"com.apple."` matches every Apple app.
    public func usesSwipe(_ bundleID: String) -> Bool {
        !buttons.contains { bundleID.hasPrefix($0) } && swipe.contains { bundleID.hasPrefix($0) }
    }
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

    /// Compiles a name -> action map over `base`; `index` turns a name into a table index.
    static func table(_ map: [String: Action], path: String, over base: OutputTable,
                      index: (String, String) throws(InvalidConfig) -> Int) throws(InvalidConfig) -> OutputTable {
        var table = base
        for (name, action) in map {
            let path = "\(path).\(name)"
            table[try index(name, path)] = try output(action, path: path)
        }
        return table
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
        case let .keys(text):
            if let media = MediaKey.byName[text] { .media(media) } else { .key(try combo(text, path: path)) }
        }
    }
}
