/// L0 remap: HID usage -> HID usage, applied by the HID event system (no permissions).
public struct HIDMapping: Sendable, Equatable {
    public var from: UInt32
    public var to: UInt32
    public var device: DeviceMatch?
}

/// What the Caps Lock LED shows once Caps Lock is remapped.
public enum CapsLockLED: String, Sendable, Equatable {
    /// Always off.
    case off
    /// On while Caps Lock is held.
    case held
}

/// The Caps Lock layer.
public struct Layer: Sendable, Equatable {
    /// Caps Lock is turned into this key at L0, then tracked by the event tap.
    public static let trigger = KeyNames.key("f18")!

    public var alone: Output?
    /// Added to unmapped keys while the layer is held.
    public var hold: Modifiers
    public var led: CapsLockLED
    public var tapTimeoutNs: UInt64
    public var base: OutputTable
    public var apps: [String: OutputTable]
}

/// `KeyboardConfig` compiled into L0 mappings and L1 lookup tables. Compiling also validates
/// every key name, so a config that compiles can be applied without further checks.
public struct KeyboardPlan: Sendable, Equatable {
    public var hid: [HIDMapping] = []
    /// `[map]` entries the event tap handles (combos, actions, keys an app overrides).
    public var map = OutputTable.keys
    public var apps: [String: OutputTable] = [:]
    public var layer: Layer?

    public var needsEventTap: Bool { layer != nil || !map.isEmpty || !apps.isEmpty }

    public init() {}

    public init(_ config: KeyboardConfig) throws(InvalidConfig) {
        let capsLock = KeyNames.key("capslock")!
        func from(_ name: String, _ path: String) throws(InvalidConfig) -> Key {
            let key = try Compile.key(name, path: path)
            if config.capslock != nil, key == capsLock {
                throw InvalidConfig(message: "\(path): capslock is already configured in [capslock]")
            }
            return key
        }
        /// Index into a tap table. The tap never sees modifier keys go down, only flag changes.
        func tapKey(_ name: String, _ path: String) throws(InvalidConfig) -> Int {
            let key = try from(name, path)
            guard !key.isModifier else {
                throw InvalidConfig(message: "\(path): a modifier key can only become another key, in [map] or [[device]]")
            }
            return Int(key.code)
        }

        // Device remaps come first: for the same key, the more specific mapping wins.
        for (i, device) in config.device.enumerated() {
            for (name, target) in device.map.sorted(by: { $0.key < $1.key }) {
                let path = "device[\(i)].map.\(name)"
                let to = try Compile.key(target, path: path)
                hid.append(HIDMapping(from: try from(name, path).usage, to: to.usage, device: device.match))
            }
        }

        // Keys an app overrides go through the tap, the only layer that knows the frontmost app.
        var overridden = Set<Int>()
        for (i, app) in config.app.enumerated() {
            for name in app.map.keys { overridden.insert(try tapKey(name, "app[\(i)].map.\(name)")) }
        }
        for (name, action) in config.map.sorted(by: { $0.key < $1.key }) {
            let path = "map.\(name)"
            let key = try from(name, path)
            if case let .key(to)? = try Compile.output(action, path: path), to.modifiers.isEmpty,
               !overridden.contains(Int(key.code)) {
                hid.append(HIDMapping(from: key.usage, to: to.key.usage, device: nil)) // works in password fields too
            } else {
                map = try Compile.table([name: action], path: "map", over: map, index: tapKey)
            }
        }
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "app[\(i)].map", over: map, index: tapKey)
        }

        guard let caps = config.capslock else { return }
        hid.append(HIDMapping(from: capsLock.usage, to: Layer.trigger.usage, device: nil))
        var hold: Modifiers = []
        if let text = caps.hold {
            guard let parsed = Modifiers(parsing: text) else {
                throw InvalidConfig(message: "capslock.hold: '\(text)' isn't a modifier list; use e.g. \"shift-ctrl-opt\", \"meh\" or \"hyper\"")
            }
            hold = parsed
        }
        var led = CapsLockLED.off
        if let text = caps.led {
            guard let parsed = CapsLockLED(rawValue: text) else {
                throw InvalidConfig(message: "capslock.led: '\(text)' isn't valid; use \"off\" or \"held\"")
            }
            led = parsed
        }
        let layerKey = { (name: String, path: String) throws(InvalidConfig) -> Int in
            Int(try Compile.key(name, path: path).code)
        }
        let base = try Compile.table(caps.map, path: "capslock.map", over: .keys, index: layerKey)
        var apps: [String: OutputTable] = [:]
        for (i, app) in caps.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "capslock.app[\(i)].map", over: base, index: layerKey)
        }
        layer = Layer(
            alone: try Compile.output(caps.alone, path: "capslock.alone"),
            hold: hold,
            led: led,
            tapTimeoutNs: UInt64(max(0, caps.tapTimeoutMs)) * 1_000_000,
            base: base,
            apps: apps
        )
    }
}
