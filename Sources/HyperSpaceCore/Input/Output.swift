/// What a remapped key or mouse button produces.
public enum Output: Sendable, Equatable {
    /// Swallow the input.
    case drop
    /// A key code with modifiers. Key names refer to physical positions (US layout).
    case key(Combo)
    /// A named system action: navigation, media keys, Mission Control, clicks...
    case system(SystemAction)
    case scroll(ScrollStep)
    case shell(String)
    case wm(String)
}

extension Output {
    /// An action as written in the config, e.g. `volume.up`, `cmd-space`, `scroll.down`.
    public init(parsing text: String) throws(InvalidConfig) {
        self = try Compile.output(.keys(text), path: text) ?? .drop
    }
}

public enum Navigation: Sendable, Equatable {
    case back, forward
}

/// Every named action, by its config name.
public enum SystemAction: String, Sendable, CaseIterable {
    /// Back/forward in the app under the input, independent of the keyboard layout.
    case navigateBack = "navigate.back", navigateForward = "navigate.forward"

    case volumeUp = "volume.up", volumeDown = "volume.down", volumeMute = "volume.mute"
    case brightnessUp = "brightness.up", brightnessDown = "brightness.down"
    case keyboardBrightnessUp = "keyboard.brightness.up", keyboardBrightnessDown = "keyboard.brightness.down"
    case mediaPlay = "media.play", mediaNext = "media.next", mediaPrevious = "media.previous"
    case mediaForward = "media.forward", mediaRewind = "media.rewind"

    case missionControl = "mission.control", missionWindows = "mission.windows"
    case missionDesktop = "mission.desktop", missionLaunchpad = "mission.launchpad"
    case spaceLeft = "space.left", spaceRight = "space.right"
    case lookUp = "lookup", smartZoom = "zoom.smart"
    case windowMaximize = "window.maximize", windowMinimize = "window.minimize"

    case clickLeft = "click.left", clickDouble = "click.double", clickRight = "click.right"
    case clickMiddle = "click.middle", clickBack = "click.back", clickForward = "click.forward"

    /// The `NX_KEYTYPE_*` code of a media key, sent like a keyboard's function row.
    public var mediaKey: Int32? {
        switch self {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .volumeMute: 7
        case .mediaPlay: 16
        case .mediaNext: 17
        case .mediaPrevious: 18
        case .mediaForward: 19
        case .mediaRewind: 20
        case .keyboardBrightnessUp: 21
        case .keyboardBrightnessDown: 22
        default: nil
        }
    }
}

/// A synthesized scroll: positive `dy` is up, positive `dx` is left (wheel conventions).
public struct ScrollStep: Sendable, Equatable {
    public var dx: Int32
    public var dy: Int32
    /// Pixels instead of lines.
    public var pixels: Bool
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

    static func scroll(_ direction: String, _ amount: ScrollAmount, path: String) throws(InvalidConfig) -> ScrollStep {
        let (value, pixels) = switch amount {
        case let .lines(n): (n, false)
        case let .pixels(n): (n, true)
        }
        guard value > 0, value <= 10_000 else { throw InvalidConfig(message: "\(path): the scroll amount must be positive") }
        let n = Int32(value)
        switch direction {
        case "up": return ScrollStep(dx: 0, dy: n, pixels: pixels)
        case "down": return ScrollStep(dx: 0, dy: -n, pixels: pixels)
        case "left": return ScrollStep(dx: n, dy: 0, pixels: pixels)
        case "right": return ScrollStep(dx: -n, dy: 0, pixels: pixels)
        default: throw InvalidConfig(message: "\(path): unknown scroll direction '\(direction)'; use up, down, left or right")
        }
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
        case let .scroll(direction, amount): .scroll(try scroll(direction, amount, path: path))
        case let .keys(text):
            if let action = SystemAction(rawValue: text) {
                .system(action)
            } else if text.hasPrefix("scroll."), case let direction = String(text.dropFirst(7)) {
                .scroll(try scroll(direction, .lines(3), path: path))
            } else {
                .key(try combo(text, path: path))
            }
        }
    }
}
