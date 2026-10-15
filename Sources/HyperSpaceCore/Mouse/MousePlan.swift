/// `MouseConfig` compiled for the event tap. Buttons use CoreGraphics numbers
/// (0 left, 1 right, 2 middle, 3 back, 4 forward...).
public struct MousePlan: Sendable, Equatable {
    public var buttons = OutputTable.buttons
    public var apps: [String: OutputTable] = [:]
    public var scroll: ScrollConfig?
    public var navigation = NavigationRules()

    public var needsEventTap: Bool { !buttons.isEmpty || !apps.isEmpty || scroll != nil }

    public init() {}

    public init(_ config: MouseConfig) throws(InvalidConfig) {
        buttons = try Compile.table(config.buttons, path: "buttons", over: .buttons, index: MousePlan.button)
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "app[\(i)].buttons", over: buttons, index: MousePlan.button)
        }
        if let lines = config.scroll?.lines, !(1...20).contains(lines) {
            throw InvalidConfig(message: "scroll.lines: must be between 1 and 20")
        }
        scroll = config.scroll
        navigation = NavigationRules(config.navigate)
    }

    /// `button1`...`button31`, or `middle`, `back`, `forward`.
    private static func button(_ name: String, path: String) throws(InvalidConfig) -> Int {
        let aliases = ["middle": 2, "back": 3, "forward": 4]
        guard let number = aliases[name] ?? (name.hasPrefix("button") ? Int(name.dropFirst(6)) : nil),
              (0..<32).contains(number) else {
            throw InvalidConfig(message: "\(path): unknown mouse input '\(name)'; use button1...button31, middle, back or forward")
        }
        guard number > 0 else { throw InvalidConfig(message: "\(path): the left button can't be remapped") }
        return number
    }
}
