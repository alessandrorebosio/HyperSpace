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
    public var simple = OutputTable.keys
    public var layer: Layer?

    public var needsEventTap: Bool { layer != nil || !simple.isEmpty }

    public init() {}

    public init(_ config: KeyboardConfig) throws(InvalidConfig) {
        let capsLock = KeyNames.key("capslock")!
        for (i, remap) in config.simple.enumerated() {
            let path = "simple[\(i)]"
            let from = try Compile.key(remap.from, path: "\(path).from")
            let to = try Compile.combo(remap.to, path: "\(path).to")
            if config.capslock != nil, from == capsLock {
                throw InvalidConfig(message: "\(path).from: capslock is already configured in [capslock]")
            }
            if to.modifiers.isEmpty {
                hid.append(HIDMapping(from: from.usage, to: to.key.usage, device: remap.device))
                continue
            }
            // A combo can't be expressed at HID level: the event tap handles it.
            guard !from.isModifier else {
                throw InvalidConfig(message: "\(path): remapping a modifier to a combo is not supported")
            }
            guard remap.device == nil else {
                throw InvalidConfig(message: "\(path): a device filter needs a single key as target, not a combo")
            }
            simple[Int(from.code)] = .key(to)
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
        let base = try KeyboardPlan.table(caps.map, path: "capslock.map", over: .keys)
        var apps: [String: OutputTable] = [:]
        for (i, app) in caps.app.enumerated() {
            apps[app.bundleID] = try KeyboardPlan.table(app.map, path: "capslock.app[\(i)].map", over: base)
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

    private static func table(_ map: [String: Action], path: String, over base: OutputTable) throws(InvalidConfig) -> OutputTable {
        var table = base
        for (name, action) in map {
            table[Int(try Compile.key(name, path: "\(path).\(name)").code)] = try Compile.output(action, path: "\(path).\(name)")
        }
        return table
    }
}
