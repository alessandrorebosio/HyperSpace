/// `MouseConfig` compiled for the event tap. Buttons use CoreGraphics numbers
/// (0 left, 1 right, 2 middle, 3 back, 4 forward...).
public struct MousePlan: Sendable, Equatable {
    public var buttons = OutputTable.buttons
    public var apps: [String: OutputTable] = [:]
    public var scroll: ScrollConfig?

    public var needsEventTap: Bool { !buttons.isEmpty || !apps.isEmpty || scroll != nil }

    public init() {}

    public init(_ config: MouseConfig) throws(InvalidConfig) {
        buttons = try MousePlan.table(config.buttons, path: "mouse.buttons", over: .buttons)
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try MousePlan.table(app.buttons, path: "mouse.app[\(i)].buttons", over: buttons)
        }
        if let lines = config.scroll?.lines, !(1...20).contains(lines) {
            throw InvalidConfig(message: "mouse.scroll.lines: must be between 1 and 20")
        }
        scroll = config.scroll
    }

    private static func table(_ map: [String: Action], path: String, over base: OutputTable) throws(InvalidConfig) -> OutputTable {
        var table = base
        for (name, action) in map {
            table[try button(name, path: "\(path).\(name)")] = try Compile.output(action, path: "\(path).\(name)")
        }
        return table
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
