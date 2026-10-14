/// The whole `helm.toml`. Every section is optional; a missing section means "feature off".
public struct Config: Sendable, Equatable {
    public var keyboard = KeyboardConfig()
    public var mouse = MouseConfig()
    public var wm = WMConfig()

    public init() {}
}

// MARK: - Keyboard

public struct KeyboardConfig: Sendable, Equatable {
    /// Static 1:1 remaps, applied at HID level when possible (L0).
    public var simple: [SimpleRemap] = []
    /// Caps Lock layer. `nil` means Caps Lock is left alone.
    public var capslock: CapsLockConfig?

    public init() {}
}

public struct SimpleRemap: Sendable, Equatable {
    public var from: String
    public var to: String
    public var device: DeviceMatch?
}

/// Once configured, Caps Lock no longer toggles caps lock: it only does what is mapped here.
public struct CapsLockConfig: Sendable, Equatable {
    /// Action when Caps Lock is tapped alone.
    public var alone: Action = .none
    /// Modifiers added to every unmapped key while Caps Lock is held, e.g. `"shift-ctrl-opt"`,
    /// `"meh"` (⇧⌃⌥) or `"hyper"` (⇧⌃⌥⌘).
    public var hold: String?
    public var tapTimeoutMs = 200
    /// Caps + key. Keys not listed keep their normal behavior.
    public var map: [String: Action] = [:]
    public var app: [AppKeyMap] = []

    public init() {}
}

public struct AppKeyMap: Sendable, Equatable {
    public var bundleID: String
    public var map: [String: Action]
}

public struct DeviceMatch: Sendable, Equatable {
    public var vendor: Int?
    public var product: Int?
}

// MARK: - Mouse

public struct MouseConfig: Sendable, Equatable {
    /// Input name (e.g. `button3`, `hidpp:0x00fd`) -> action, for every mouse.
    public var buttons: [String: Action] = [:]
    public var app: [AppMouseMap] = []
    /// Wheel scrolling (notched mice). Trackpads and smooth-scrolling mice are never touched.
    public var scroll: ScrollConfig?
    public var device: [MouseDevice] = []

    public init() {}
}

public struct AppMouseMap: Sendable, Equatable {
    public var bundleID: String
    public var buttons: [String: Action]
}

public struct MouseDevice: Sendable, Equatable {
    public var match: DeviceMatch
    public var scroll: ScrollConfig?
    public var buttons: [String: Action] = [:]
}

public struct ScrollConfig: Sendable, Equatable {
    public var reverse = false
    public var linear = false
    public var lines: Int?
}

// MARK: - Window manager

public struct WMConfig: Sendable, Equatable {
    public var enabled = false
    public var gaps = Gaps()
    /// Hotkey (e.g. `alt-shift-h`) -> WM command (e.g. `move left`).
    public var bindings: [String: String] = [:]
    public var rule: [WMRule] = []

    public init() {}
}

public struct Gaps: Sendable, Equatable {
    public var inner = 0
    public var outer = 0
}

public struct WMRule: Sendable, Equatable {
    public var app: String
    public var layout: String?
    public var workspace: String?
}

// MARK: - Decoding

extension Config: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case keyboard, mouse, wm }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboard = try c.decode(.keyboard, default: KeyboardConfig())
        mouse = try c.decode(.mouse, default: MouseConfig())
        wm = try c.decode(.wm, default: WMConfig())
    }
}

extension KeyboardConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case simple, capslock }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        simple = try c.decode(.simple, default: [])
        capslock = try c.decodeIfPresent(CapsLockConfig.self, forKey: .capslock)
    }
}

extension SimpleRemap: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case from, to, device }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        device = try c.decodeIfPresent(DeviceMatch.self, forKey: .device)
    }
}

extension CapsLockConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case alone, hold, tapTimeoutMs = "tap_timeout_ms", map, app
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alone = try c.decode(.alone, default: .none)
        hold = try c.decodeIfPresent(String.self, forKey: .hold)
        tapTimeoutMs = try c.decode(.tapTimeoutMs, default: 200)
        map = try c.decode(.map, default: [:])
        app = try c.decode(.app, default: [])
    }
}

extension AppKeyMap: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID = "bundle_id", map }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        map = try c.decode(.map, default: [:])
    }
}

extension DeviceMatch: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case vendor, product }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try c.decodeIfPresent(Int.self, forKey: .vendor)
        product = try c.decodeIfPresent(Int.self, forKey: .product)
    }
}

extension MouseConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case buttons, app, scroll, device }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        buttons = try c.decode(.buttons, default: [:])
        app = try c.decode(.app, default: [])
        scroll = try c.decodeIfPresent(ScrollConfig.self, forKey: .scroll)
        device = try c.decode(.device, default: [])
    }
}

extension AppMouseMap: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID = "bundle_id", buttons }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        buttons = try c.decode(.buttons, default: [:])
    }
}

extension MouseDevice: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case match, scroll, buttons }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = try c.decode(DeviceMatch.self, forKey: .match)
        scroll = try c.decodeIfPresent(ScrollConfig.self, forKey: .scroll)
        buttons = try c.decode(.buttons, default: [:])
    }
}

extension ScrollConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case reverse, linear, lines }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reverse = try c.decode(.reverse, default: false)
        linear = try c.decode(.linear, default: false)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines)
    }
}

extension WMConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, gaps, bindings, rule }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(.enabled, default: false)
        gaps = try c.decode(.gaps, default: Gaps())
        bindings = try c.decode(.bindings, default: [:])
        rule = try c.decode(.rule, default: [])
    }
}

extension Gaps: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case inner, outer }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inner = try c.decode(.inner, default: 0)
        outer = try c.decode(.outer, default: 0)
    }
}

extension WMRule: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case app, layout, workspace }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        layout = try c.decodeIfPresent(String.self, forKey: .layout)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
    }
}
