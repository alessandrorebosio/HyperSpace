/// The whole config: keyboard.toml, mouse.toml and wm.toml. A missing file means "feature off".
public struct Config: Sendable, Equatable {
    public var keyboard = KeyboardConfig()
    public var mouse = MouseConfig()
    public var wm = WMConfig()

    public init() {}
}

// MARK: - Keyboard

public struct KeyboardConfig: Sendable, Equatable {
    /// Key -> action, always active. Key -> key is applied at HID level when possible (L0).
    public var map: [String: Action] = [:]
    public var app: [AppMap] = []
    /// Key -> key remaps for one keyboard only.
    public var device: [DeviceMap] = []
    /// Caps Lock layer. `nil` means Caps Lock is left alone.
    public var capslock: CapsLockConfig?

    public init() {}
}

/// Once configured, Caps Lock no longer toggles caps lock: it only does what is mapped here.
public struct CapsLockConfig: Sendable, Equatable {
    /// Action when Caps Lock is tapped alone.
    public var alone: Action = .none
    /// Modifiers added to every unmapped key while Caps Lock is held, e.g. `"shift-ctrl-opt"`,
    /// `"meh"` (⇧⌃⌥) or `"hyper"` (⇧⌃⌥⌘).
    public var hold: String?
    /// Caps Lock LED: "off" (always off, default) or "held" (on while Caps Lock is held).
    public var led: String?
    public var tapTimeoutMs = 200
    /// Caps + key. Keys not listed keep their normal behavior.
    public var map: [String: Action] = [:]
    public var app: [AppMap] = []

    public init() {}
}

/// Overrides while one app is in front: key or button name -> action.
public struct AppMap: Sendable, Equatable {
    public var bundleID: String
    public var map: [String: Action]
}

public struct DeviceMatch: Sendable, Equatable {
    public var vendor: Int?
    public var product: Int?
}

public struct DeviceMap: Sendable, Equatable {
    public var match: DeviceMatch
    /// Key -> key.
    public var map: [String: String]
}

// MARK: - Mouse

public struct MouseConfig: Sendable, Equatable {
    /// Button name (e.g. `button3`, `back`) -> action, for every mouse.
    public var buttons: [String: Action] = [:]
    /// Per-app overrides; `map` holds button names.
    public var app: [AppMap] = []
    /// Wheel scrolling (notched mice). Trackpads and smooth-scrolling mice are never touched.
    public var scroll: ScrollConfig?
    public var navigate = NavigateConfig()

    public init() {}
}

public struct ScrollConfig: Sendable, Equatable {
    public var reverse = false
    public var linear = false
    public var lines: Int?
}

/// How `navigate.back`/`navigate.forward` reach each app (bundle id prefixes).
public struct NavigateConfig: Sendable, Equatable {
    /// Extra apps that get a trackpad swipe.
    public var swipe: [String] = []
    /// Apps that get mouse buttons 4/5, even if they'd get a swipe by default.
    public var buttons: [String] = []
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

extension KeyboardConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case map, app, device, capslock }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        map = try c.decode(.map, default: [:])
        app = try c.decode(.app, default: [])
        device = try c.decode(.device, default: [])
        capslock = try c.decodeIfPresent(CapsLockConfig.self, forKey: .capslock)
    }
}

extension CapsLockConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case alone, hold, led, tapTimeoutMs = "tap_timeout_ms", map, app
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        alone = try c.decode(.alone, default: .none)
        hold = try c.decodeIfPresent(String.self, forKey: .hold)
        led = try c.decodeIfPresent(String.self, forKey: .led)
        tapTimeoutMs = try c.decode(.tapTimeoutMs, default: 200)
        map = try c.decode(.map, default: [:])
        app = try c.decode(.app, default: [])
    }
}

extension AppMap: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID = "bundle_id", map }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        map = try c.decode(.map, default: [:])
    }
}

/// mouse.toml's `[[app]]`, which names its table `buttons`.
private struct AppButtons: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID = "bundle_id", buttons }
    let app: AppMap

    init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        app = AppMap(bundleID: try c.decode(String.self, forKey: .bundleID), map: try c.decode(.buttons, default: [:]))
    }
}

extension DeviceMap: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case vendor, product, map }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        match = DeviceMatch(vendor: try c.decodeIfPresent(Int.self, forKey: .vendor),
                            product: try c.decodeIfPresent(Int.self, forKey: .product))
        map = try c.decode(.map, default: [:])
    }
}

extension MouseConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case buttons, app, scroll, navigate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        buttons = try c.decode(.buttons, default: [:])
        app = try c.decode(.app, default: [AppButtons]()).map(\.app)
        scroll = try c.decodeIfPresent(ScrollConfig.self, forKey: .scroll)
        navigate = try c.decode(.navigate, default: NavigateConfig())
    }
}

extension ScrollConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case reverse, linear, lines }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        reverse = try c.decode(.reverse, default: false)
        linear = try c.decode(.linear, default: false)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines)
    }
}

extension NavigateConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case swipe, buttons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        swipe = try c.decode(.swipe, default: [])
        buttons = try c.decode(.buttons, default: [])
    }
}

extension WMConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, gaps, bindings, rule }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        enabled = try c.decode(.enabled, default: false)
        gaps = try c.decode(.gaps, default: Gaps())
        bindings = try c.decode(.bindings, default: [:])
        rule = try c.decode(.rule, default: [])
    }
}

extension Gaps: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case inner, outer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        inner = try c.decode(.inner, default: 0)
        outer = try c.decode(.outer, default: 0)
    }
}

extension WMRule: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case app, layout, workspace }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        layout = try c.decodeIfPresent(String.self, forKey: .layout)
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
    }
}
