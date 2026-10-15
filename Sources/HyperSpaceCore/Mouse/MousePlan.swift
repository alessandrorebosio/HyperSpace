/// Mouse inputs as table indices. 0...31 are CoreGraphics button numbers (0 left, 1 right,
/// 2 middle, 3 back, 4 forward...). 32...39 are Logitech controls read over HID++, like the
/// Lift's DPI button, which never reach macOS on their own.
public enum MouseButtons {
    public static let count = 40
    static let logitech = 32..<40

    static let aliases = ["middle": 2, "back": 3, "forward": 4]
    /// Logitech control ids (CIDs) by name; any other one is written `cid.0x00c3`.
    static let logitechAliases: [String: UInt16] = ["dpi": 0x00FD, "gesture": 0x00C3]
}

/// What the wheel and mouse movement do while a button is held (`[hold.<button>]`).
public struct HoldPlan: Sendable, Equatable {
    public enum Direction: Int, Sendable, CaseIterable { case up, down, left, right }

    /// Per wheel notch, by `Direction`.
    public var scroll = [Output?](repeating: nil, count: 4)
    /// Per `distance` points of movement, by `Direction`.
    public var move = [Output?](repeating: nil, count: 4)
    public var distance = 60.0

    public var hasMove: Bool { move.contains { $0 != nil } }
}

/// `[scroll]` validated. Applied to notched wheel events only.
public struct ScrollPlan: Sendable, Equatable {
    public var reverseVertical = false
    public var reverseHorizontal = false
    public var linear = false
    public var smooth = false
    /// Lines per notch when linear or smooth.
    public var lines = 3
    public var fast: Modifiers = []
    public var fastFactor = 3.0
}

/// `[pointer]` and `[[device]]` validated: speed and acceleration per device.
public struct PointerPlan: Sendable, Equatable {
    public var global = PointerConfig()
    public var devices: [PointerDevice] = []

    public var isEmpty: Bool { global == PointerConfig() && devices.isEmpty }

    public init(global: PointerConfig = PointerConfig(), devices: [PointerDevice] = []) {
        self.global = global
        self.devices = devices
    }

    /// Settings for one pointing device: the first matching `[[device]]`, else `[pointer]`
    /// for mice (`isMouse`), else nothing (trackpads keep the macOS settings).
    public func settings(name: String, vendor: Int?, product: Int?, isMouse: Bool) -> PointerConfig? {
        if let device = devices.first(where: { $0.match.matches(name: name, vendor: vendor, product: product) }) {
            return device.pointer
        }
        return isMouse && global != PointerConfig() ? global : nil
    }
}

extension DeviceMatch {
    public func matches(name: String, vendor: Int?, product: Int?) -> Bool {
        (self.name.map { name.localizedCaseInsensitiveContains($0) } ?? true)
            && (self.vendor.map { $0 == vendor } ?? true)
            && (self.product.map { $0 == product } ?? true)
    }
}

/// `MouseConfig` compiled for the event tap, the pointer settings and the Logitech reader.
/// Compiling validates every name, so a config that compiles can be applied as is.
public struct MousePlan: Sendable, Equatable {
    public var buttons = OutputTable.buttons
    public var apps: [String: OutputTable] = [:]
    /// By button index; a button with a hold plan fires its own action only when tapped.
    public var holds = [HoldPlan?](repeating: nil, count: MouseButtons.count)
    public var scroll: ScrollPlan?
    public var pointer = PointerPlan()
    public var navigation = NavigationRules()
    /// Logitech control id -> button index, for the controls the config uses.
    public var logitech: [UInt16: Int] = [:]

    public var needsEventTap: Bool {
        !buttons.isEmpty || !apps.isEmpty || scroll != nil || holds.contains { $0 != nil }
    }

    /// The tap also needs plain mouse moves when a Logitech control has a move gesture:
    /// those controls don't make macOS send drag events.
    public var needsMoveEvents: Bool {
        MouseButtons.logitech.contains { holds[$0]?.hasMove == true }
    }

    public init() {}

    public init(_ config: MouseConfig) throws(InvalidConfig) {
        var logitech: [UInt16: Int] = [:]
        /// `button1`...`button31`, `middle`, `back`, `forward`, `dpi`, `gesture` or `cid.0x00c3`.
        func button(_ name: String, path: String) throws(InvalidConfig) -> Int {
            if let cid = MouseButtons.logitechAliases[name] ?? MousePlan.cid(name) {
                if let index = logitech[cid] { return index }
                guard logitech.count < MouseButtons.logitech.count else {
                    throw InvalidConfig(message: "\(path): at most \(MouseButtons.logitech.count) Logitech controls can be used")
                }
                let index = MouseButtons.logitech.lowerBound + logitech.count
                logitech[cid] = index
                return index
            }
            guard let number = MouseButtons.aliases[name] ?? (name.hasPrefix("button") ? Int(name.dropFirst(6)) : nil),
                  (0..<32).contains(number) else {
                throw InvalidConfig(message: "\(path): unknown mouse input '\(name)'; use button1...button31, middle, back, forward, dpi, gesture or cid.0x00c3")
            }
            guard number > 0 else { throw InvalidConfig(message: "\(path): the left button can't be remapped") }
            return number
        }

        // Sorted, so Logitech indices are stable across reloads of the same file.
        for name in config.buttons.keys.sorted() + config.hold.keys.sorted() { _ = try button(name, path: "buttons.\(name)") }

        buttons = try Compile.table(config.buttons, path: "buttons", over: .buttons, index: button)
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "app[\(i)].buttons", over: buttons, index: button)
        }
        for (name, hold) in config.hold {
            holds[try button(name, path: "hold.\(name)")] = try MousePlan.hold(hold, path: "hold.\(name)")
        }
        if let scroll = config.scroll { self.scroll = try MousePlan.scroll(scroll) }
        pointer = try MousePlan.pointer(config)
        navigation = NavigationRules(config.navigate)
        self.logitech = logitech
    }

    private static func cid(_ name: String) -> UInt16? {
        guard name.hasPrefix("cid.0x") else { return nil }
        return UInt16(name.dropFirst(6), radix: 16)
    }

    private static func hold(_ config: HoldConfig, path: String) throws(InvalidConfig) -> HoldPlan {
        var plan = HoldPlan()
        guard (5...2000).contains(config.distance) else {
            throw InvalidConfig(message: "\(path).distance: must be between 5 and 2000 points")
        }
        plan.distance = Double(config.distance)
        for (name, action) in config.map {
            let path = "\(path).\(name)"
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let direction = ["up": HoldPlan.Direction.up, "down": .down, "left": .left, "right": .right][parts[1]],
                  parts[0] == "scroll" || parts[0] == "move" else {
                throw InvalidConfig(message: "\(path): use scroll.up/.down/.left/.right, move.up/.down/.left/.right or distance")
            }
            let output = try Compile.output(action, path: path)
            if parts[0] == "scroll" { plan.scroll[direction.rawValue] = output } else { plan.move[direction.rawValue] = output }
        }
        return plan
    }

    private static func scroll(_ config: ScrollConfig) throws(InvalidConfig) -> ScrollPlan {
        var plan = ScrollPlan()
        plan.reverseVertical = config.reverse == .both || config.reverse == .vertical
        plan.reverseHorizontal = config.reverse == .both || config.reverse == .horizontal
        plan.linear = config.linear
        plan.smooth = config.smooth
        if let lines = config.lines {
            guard (1...20).contains(lines) else { throw InvalidConfig(message: "scroll.lines: must be between 1 and 20") }
            plan.lines = lines
        }
        if let fast = config.fast { plan.fast = try Compile.modifiers(fast, path: "scroll.fast") }
        guard (1...20).contains(config.fastFactor) else { throw InvalidConfig(message: "scroll.fast_factor: must be between 1 and 20") }
        plan.fastFactor = config.fastFactor
        return plan
    }

    private static func pointer(_ config: MouseConfig) throws(InvalidConfig) -> PointerPlan {
        func check(_ pointer: PointerConfig, _ path: String) throws(InvalidConfig) {
            if let speed = pointer.speed, !(0...1).contains(speed) {
                throw InvalidConfig(message: "\(path)speed: must be between 0 and 1")
            }
            if case let .curve(value)? = pointer.acceleration, !(0...20).contains(value) {
                throw InvalidConfig(message: "\(path)acceleration: must be false or between 0 and 20")
            }
        }
        try check(config.pointer, "pointer.")
        for (i, device) in config.device.enumerated() {
            guard device.match != DeviceMatch() else {
                throw InvalidConfig(message: "device[\(i)]: needs name, vendor or product")
            }
            try check(device.pointer, "device[\(i)].")
        }
        return PointerPlan(global: config.pointer, devices: config.device)
    }
}
