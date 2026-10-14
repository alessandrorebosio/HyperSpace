/// What a remapped key produces.
public enum Output: Sendable, Equatable {
    /// Swallow the input.
    case drop
    case key(Combo)
    case shell(String)
    case wm(String)
}

/// Lookup table indexed by virtual key code. `nil` means "not remapped": the key behaves normally.
public struct KeyTable: Sendable, Equatable {
    private var outputs = [Output?](repeating: nil, count: 128)

    public init() {}

    public subscript(code: UInt16) -> Output? {
        get { code < 128 ? outputs[Int(code)] : nil }
        set { if code < 128 { outputs[Int(code)] = newValue } }
    }

    public var isEmpty: Bool { outputs.allSatisfy { $0 == nil } }
}

/// L0 remap: HID usage -> HID usage, applied by the HID event system (no permissions).
public struct HIDMapping: Sendable, Equatable {
    public var from: UInt32
    public var to: UInt32
    public var device: DeviceMatch?
}

public struct Layer: Sendable, Equatable {
    /// Caps Lock is turned into this key at L0, then tracked by the event tap.
    public static let trigger = KeyNames.key("f18")!

    public var alone: Output?
    public var tapTimeoutNs: UInt64
    public var base: KeyTable
    public var apps: [String: KeyTable]
}

/// The tables the event tap uses for the frontmost app.
public struct ActiveTables: Sendable, Equatable {
    public var simple = KeyTable()
    public var layer: ActiveLayer?
    public var buttons = ButtonTable()
    public var scroll: ScrollConfig?

    public struct ActiveLayer: Sendable, Equatable {
        public var trigger: UInt16
        public var alone: Output?
        public var tapTimeoutNs: UInt64
        public var map: KeyTable
    }

    public init() {}
}

/// `KeyboardConfig` compiled into L0 mappings and L1 lookup tables. Compiling also validates
/// every key name, so a config that compiles can be applied without further checks.
public struct KeyboardPlan: Sendable, Equatable {
    public var hid: [HIDMapping] = []
    public var simple = KeyTable()
    public var layer: Layer?

    public var needsEventTap: Bool { layer != nil || !simple.isEmpty }

    public struct Error: Swift.Error, Equatable {
        public let message: String
    }

    public init() {}

    public init(_ config: KeyboardConfig) throws(Error) {
        for (i, remap) in config.simple.enumerated() {
            try addSimple(remap, path: "keyboard.simple[\(i)]", capsLockTaken: config.capslock != nil)
        }
        if let caps = config.capslock {
            hid.append(HIDMapping(from: KeyNames.key("caps_lock")!.usage, to: Layer.trigger.usage, device: nil))
            layer = Layer(
                alone: try output(caps.alone, path: "keyboard.capslock.alone"),
                tapTimeoutNs: UInt64(max(0, caps.tapTimeoutMs)) * 1_000_000,
                base: try table(caps.map, path: "keyboard.capslock.map"),
                apps: [:]
            )
            for (i, app) in caps.app.enumerated() {
                var merged = layer!.base
                for (name, action) in app.map {
                    let path = "keyboard.capslock.app[\(i)].map.\(name)"
                    merged[try key(name, path: path).code] = try output(action, path: path)
                }
                layer!.apps[app.bundleID] = merged
            }
        }
    }

    public func tables(forApp bundleID: String?) -> ActiveTables {
        var tables = ActiveTables()
        tables.simple = simple
        if let layer {
            tables.layer = .init(
                trigger: Layer.trigger.code,
                alone: layer.alone,
                tapTimeoutNs: layer.tapTimeoutNs,
                map: bundleID.flatMap { layer.apps[$0] } ?? layer.base
            )
        }
        return tables
    }

    // MARK: - Compiling

    private mutating func addSimple(_ remap: SimpleRemap, path: String, capsLockTaken: Bool) throws(Error) {
        let from = try key(remap.from, path: "\(path).from")
        guard let to = Combo(parsing: remap.to) else {
            throw Error(message: "\(path).to: unknown key or combo '\(remap.to)'")
        }
        if capsLockTaken, remap.from == "caps_lock" {
            throw Error(message: "\(path).from: caps_lock is already configured in [keyboard.capslock]")
        }
        if to.modifiers.isEmpty {
            hid.append(HIDMapping(from: from.usage, to: to.key.usage, device: remap.device))
            return
        }
        // A combo can't be expressed at HID level: the event tap handles it.
        guard !from.isModifier else {
            throw Error(message: "\(path): remapping a modifier to a combo is not supported")
        }
        guard remap.device == nil else {
            throw Error(message: "\(path): a device filter needs a single key as target, not a combo")
        }
        simple[from.code] = .key(to)
    }

    private func table(_ map: [String: Action], path: String) throws(Error) -> KeyTable {
        var table = KeyTable()
        for (name, action) in map {
            table[try key(name, path: "\(path).\(name)").code] = try output(action, path: "\(path).\(name)")
        }
        return table
    }

    private func key(_ name: String, path: String) throws(Error) -> Key {
        guard let key = KeyNames.key(name) else { throw Error(message: "\(path): unknown key '\(name)'") }
        return key
    }

    private func output(_ action: Action, path: String) throws(Error) -> Output? {
        switch action {
        case .none: return .drop
        case .passthrough: return nil
        case let .shell(command): return .shell(command)
        case let .wm(command): return .wm(command)
        case let .keys(text):
            guard let combo = Combo(parsing: text) else {
                throw Error(message: "\(path): unknown key or combo '\(text)'")
            }
            return .key(combo)
        }
    }
}
