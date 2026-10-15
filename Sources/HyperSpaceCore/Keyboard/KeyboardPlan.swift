/// L0 remap: HID usage -> HID usage, applied by the HID event system (no permissions, works
/// in password fields too).
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

/// A key that is a layer while held and `alone` when tapped: `[capslock]` or `[layer.<key>]`.
public struct Layer: Sendable, Equatable {
    /// Caps Lock is turned into F18 at L0 (so it stops toggling caps lock), then the tap
    /// treats F18 as the Caps Lock layer key.
    public static let capsLockTrigger = KeyNames.key("f18")!.code

    /// Key code the tap sees for this layer key.
    public var trigger: UInt16
    public var alone: Output?
    /// Added to unmapped keys while the layer is held.
    public var hold: Modifiers
    public var led: CapsLockLED
    public var tapTimeoutNs: UInt64
    /// Typing keys (space, return...) decide between tap and hold only once the next key is
    /// released, so fast typing ("space" then "j" overlapping) still types both. Caps Lock
    /// isn't typed, so it decides at once.
    public var permissive: Bool
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
    /// Caps Lock first, if configured.
    public var layers: [Layer] = []
    /// Key code -> action on a double tap.
    public var double = OutputTable.keys
    public var doubleTapNs: UInt64 = 300_000_000

    public var capsLock: Layer? { layers.first { $0.trigger == Layer.capsLockTrigger } }

    public var needsEventTap: Bool { !layers.isEmpty || !map.isEmpty || !apps.isEmpty || !double.isEmpty }

    public init() {}

    public init(_ config: KeyboardConfig) throws(InvalidConfig) {
        let capsLock = KeyNames.key("capslock")!
        let layerKeys = config.layer.keys
        func from(_ name: String, _ path: String) throws(InvalidConfig) -> Key {
            let key = try Compile.key(name, path: path)
            if config.capslock != nil, key == capsLock {
                throw InvalidConfig(message: "\(path): capslock is already configured in [capslock]")
            }
            if layerKeys.contains(where: { KeyNames.key($0) == key }) {
                throw InvalidConfig(message: "\(path): this key is a layer key in [layer.\(name)]")
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
                hid.append(HIDMapping(from: key.usage, to: to.key.usage, device: nil))
            } else {
                map = try Compile.table([name: action], path: "map", over: map, index: tapKey)
            }
        }
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "app[\(i)].map", over: map, index: tapKey)
        }

        if let caps = config.capslock {
            hid.append(HIDMapping(from: capsLock.usage, to: KeyNames.key(code: Layer.capsLockTrigger)!.usage, device: nil))
            layers.append(try KeyboardPlan.layer(caps, trigger: Layer.capsLockTrigger, permissive: false, path: "capslock"))
        }
        for (name, layer) in config.layer.sorted(by: { $0.key < $1.key }) {
            let path = "layer.\(name)"
            let key = try Compile.key(name, path: path)
            guard !key.isModifier, key != capsLock else {
                throw InvalidConfig(message: "\(path): use a non-modifier key (Caps Lock goes in [capslock])")
            }
            guard layer.led == nil else { throw InvalidConfig(message: "\(path).led: only [capslock] has an LED") }
            layers.append(try KeyboardPlan.layer(layer, trigger: key.code, permissive: true, path: path))
        }

        // Double taps: modifier keys are fine here, the tap watches their flag changes.
        double = try Compile.table(config.double, path: "double", over: .keys) { name, path throws(InvalidConfig) in
            Int(try from(name, path).code)
        }
        guard (100...1000).contains(config.doubleTapMs) else {
            throw InvalidConfig(message: "double_tap_ms: must be between 100 and 1000")
        }
        doubleTapNs = UInt64(config.doubleTapMs) * 1_000_000
    }

    private static func layer(_ config: LayerConfig, trigger: UInt16, permissive: Bool, path: String) throws(InvalidConfig) -> Layer {
        let led = try config.led.map { text throws(InvalidConfig) in
            guard let led = CapsLockLED(rawValue: text) else {
                throw InvalidConfig(message: "\(path).led: '\(text)' isn't valid; use \"off\" or \"held\"")
            }
            return led
        } ?? .off
        let key = { (name: String, path: String) throws(InvalidConfig) -> Int in Int(try Compile.key(name, path: path).code) }
        let base = try Compile.table(config.map, path: "\(path).map", over: .keys, index: key)
        var apps: [String: OutputTable] = [:]
        for (i, app) in config.app.enumerated() {
            apps[app.bundleID] = try Compile.table(app.map, path: "\(path).app[\(i)].map", over: base, index: key)
        }
        return Layer(
            trigger: trigger,
            alone: try Compile.output(config.alone, path: "\(path).alone"),
            hold: try config.hold.map { text throws(InvalidConfig) in try Compile.modifiers(text, path: "\(path).hold") } ?? [],
            led: led,
            tapTimeoutNs: UInt64(max(0, config.tapTimeoutMs)) * 1_000_000,
            permissive: permissive,
            base: base,
            apps: apps
        )
    }
}
