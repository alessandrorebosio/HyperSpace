/// Lookup table indexed by CoreGraphics button number (0 left, 1 right, 2 middle, 3 back, 4 forward...).
public struct ButtonTable: Sendable, Equatable {
    public static let count = 32
    private var outputs = [Output?](repeating: nil, count: ButtonTable.count)

    public init() {}

    public subscript(button: Int) -> Output? {
        get { (0..<ButtonTable.count).contains(button) ? outputs[button] : nil }
        set { if (0..<ButtonTable.count).contains(button) { outputs[button] = newValue } }
    }

    public var isEmpty: Bool { outputs.allSatisfy { $0 == nil } }
}

/// `MouseConfig` compiled for the event tap.
public struct MousePlan: Sendable, Equatable {
    public var buttons = ButtonTable()
    public var apps: [String: ButtonTable] = [:]
    public var scroll: ScrollConfig?

    public var needsEventTap: Bool { !buttons.isEmpty || !apps.isEmpty || scroll != nil }

    public struct Error: Swift.Error, Equatable {
        public let message: String
    }

    public init() {}

    public init(_ config: MouseConfig) throws(Error) {
        if !config.device.isEmpty {
            throw Error(message: "mouse.device: per-device settings aren't supported yet; use [mouse.buttons] and [mouse.scroll]")
        }
        buttons = try MousePlan.table(config.buttons, path: "mouse.buttons")
        for (i, app) in config.app.enumerated() {
            var merged = buttons
            for (name, action) in app.buttons {
                let path = "mouse.app[\(i)].buttons.\(name)"
                merged[try MousePlan.button(name, path: path)] = try MousePlan.output(action, path: path)
            }
            apps[app.bundleID] = merged
        }
        scroll = config.scroll
        if let lines = scroll?.lines, !(1...20).contains(lines) {
            throw Error(message: "mouse.scroll.lines: must be between 1 and 20")
        }
    }

    public func buttons(forApp bundleID: String?) -> ButtonTable {
        bundleID.flatMap { apps[$0] } ?? buttons
    }

    /// `button2`...`button31`, or `middle`, `back`, `forward`.
    static func button(_ name: String, path: String) throws(Error) -> Int {
        let aliases = ["middle": 2, "back": 3, "forward": 4]
        let number = aliases[name] ?? (name.hasPrefix("button") ? Int(name.dropFirst(6)) : nil)
        if name.hasPrefix("hidpp:") {
            throw Error(message: "\(path): Logitech HID++ inputs aren't supported yet")
        }
        guard let number, (0..<ButtonTable.count).contains(number) else {
            throw Error(message: "\(path): unknown mouse input '\(name)'; use button2...button31, middle, back or forward")
        }
        guard number >= 1 else { throw Error(message: "\(path): the left button can't be remapped") }
        return number
    }

    private static func table(_ map: [String: Action], path: String) throws(Error) -> ButtonTable {
        var table = ButtonTable()
        for (name, action) in map {
            table[try button(name, path: "\(path).\(name)")] = try output(action, path: "\(path).\(name)")
        }
        return table
    }

    private static func output(_ action: Action, path: String) throws(Error) -> Output? {
        switch Output.from(action) {
        case let .success(output): return output
        case let .failure(e): throw Error(message: "\(path): unknown key or combo '\(e.text)'")
        }
    }
}

/// Keyboard and mouse plans together: what the event tap needs.
public struct InputPlan: Sendable, Equatable {
    public var keyboard = KeyboardPlan()
    public var mouse = MousePlan()

    public var needsEventTap: Bool { keyboard.needsEventTap || mouse.needsEventTap }

    public init() {}

    public init(_ config: Config) throws(ConfigError) {
        do {
            keyboard = try KeyboardPlan(config.keyboard)
        } catch {
            throw ConfigError(path: "", message: error.message)
        }
        do {
            mouse = try MousePlan(config.mouse)
        } catch {
            throw ConfigError(path: "", message: error.message)
        }
    }

    public func tables(forApp bundleID: String?) -> ActiveTables {
        var tables = keyboard.tables(forApp: bundleID)
        tables.buttons = mouse.buttons(forApp: bundleID)
        tables.scroll = mouse.scroll
        return tables
    }
}
