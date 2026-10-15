/// The whole config: keyboard.toml, mouse.toml and wm.toml, as written by the user.
/// A missing file means "feature off". Plans (`KeyboardPlan`, `MousePlan`) validate and compile it.
public struct Config: Sendable, Equatable {
    public var keyboard = KeyboardConfig()
    public var mouse = MouseConfig()
    public var wm = WMConfig()

    public init() {}
}

// MARK: - Keyboard (keyboard.toml)

public struct KeyboardConfig: Sendable, Equatable {
    /// `[map]`: key -> action, always active. Key -> key is applied at HID level when possible.
    public var map: [String: Action] = [:]
    /// `[[app]]`: `[map]` overrides while one app is in front.
    public var app: [AppMap] = []
    /// `[[device]]`: key -> key remaps for one keyboard only.
    public var device: [DeviceMap] = []
    /// `[capslock]`: the Caps Lock layer. `nil` leaves Caps Lock alone.
    public var capslock: LayerConfig?
    /// `[layer.<key>]`: any other key as a layer or dual-role key.
    public var layer: [String: LayerConfig] = [:]
    /// `[double]`: key -> action on a double tap. Modifier keys work too.
    public var double: [String: Action] = [:]
    /// Maximum time between the two taps of a double tap.
    public var doubleTapMs = 300

    public init() {}
}

/// A key that does one thing when tapped alone and another while held: `alone` on a tap,
/// `hold` modifiers or `map` actions for keys pressed meanwhile. Caps Lock's `[capslock]`
/// and every `[layer.<key>]` share this shape.
public struct LayerConfig: Sendable, Equatable {
    /// Action when the key is tapped alone.
    public var alone: Action = .none
    /// Modifiers added to every unmapped key while held, e.g. `"shift-ctrl-opt"` (⇧⌃⌥) or
    /// `"shift-ctrl-opt-cmd"` (⇧⌃⌥⌘). A layer with only `alone` and `hold` is a dual-role key.
    public var hold: String?
    /// Caps Lock only. LED: "off" (always off, default) or "held" (on while Caps Lock is held).
    public var led: String?
    /// Held longer than this, the key is no longer a tap: `alone` doesn't fire.
    public var tapTimeoutMs = 200
    /// Layer key + key -> action. Keys not listed keep their normal behavior (plus `hold`).
    public var map: [String: Action] = [:]
    public var app: [AppMap] = []

    public init() {}
}

/// Overrides while one app is in front: key or button name -> action.
public struct AppMap: Sendable, Equatable {
    public var bundleID: String
    public var map: [String: Action]
}

/// Selects devices by any combination of fields; a missing field matches everything.
public struct DeviceMatch: Sendable, Equatable {
    /// Case-insensitive substring of the product name, e.g. "lift".
    public var name: String?
    public var vendor: Int?
    public var product: Int?

    public init(name: String? = nil, vendor: Int? = nil, product: Int? = nil) {
        self.name = name
        self.vendor = vendor
        self.product = product
    }
}

public struct DeviceMap: Sendable, Equatable {
    public var match: DeviceMatch
    /// Key -> key.
    public var map: [String: String]
}

// MARK: - Mouse (mouse.toml)

public struct MouseConfig: Sendable, Equatable {
    /// `[buttons]`: button name (e.g. `button3`, `back`, `dpi`) -> action, for every mouse.
    public var buttons: [String: Action] = [:]
    /// `[[app]]`: per-app overrides; `map` holds button names.
    public var app: [AppMap] = []
    /// `[hold.<button>]`: what the wheel and mouse movement do while a button is held.
    public var hold: [String: HoldConfig] = [:]
    /// `[scroll]`: wheel scrolling (notched mice). Trackpads are never touched.
    public var scroll: ScrollConfig?
    /// `[pointer]`: speed and acceleration for every mouse.
    public var pointer = PointerConfig()
    /// `[[device]]`: pointer settings for some mice only; they win over `[pointer]`.
    public var device: [PointerDevice] = []
    /// `[navigate]`: how navigate.back/.forward reach each app.
    public var navigate = NavigateConfig()

    public init() {}
}

/// `[hold.<button>]`: `scroll.up/.down/.left/.right` (per wheel notch) and
/// `move.left/.right/.up/.down` (a mouse gesture) -> action, while the button is held.
public struct HoldConfig: Sendable, Equatable {
    public var map: [String: Action] = [:]
    /// How far the mouse must move, in points, for a `move.*` gesture.
    public var distance = 60
}

public struct ScrollConfig: Sendable, Equatable {
    public var reverse = ScrollAxes.none
    /// Same distance per notch, no acceleration.
    public var linear = false
    /// Lines per notch when linear or smooth (1-20, default 3).
    public var lines: Int?
    /// The notched wheel scrolls smoothly, like a trackpad.
    public var smooth = false
    /// Modifiers that make scrolling faster while held, e.g. "opt".
    public var fast: String?
    /// Speed multiplier while `fast` is held.
    public var fastFactor = 3.0
}

public enum ScrollAxes: String, Sendable, Equatable {
    case none, both, vertical, horizontal
}

public struct PointerConfig: Sendable, Equatable {
    /// 0...1, slow to fast. `nil` keeps the macOS setting.
    public var speed: Double?
    /// `false` turns acceleration off (linear pointer), a number 0...20 sets the curve,
    /// `nil` keeps the macOS setting.
    public var acceleration: PointerAcceleration?

    public init(speed: Double? = nil, acceleration: PointerAcceleration? = nil) {
        self.speed = speed
        self.acceleration = acceleration
    }
}

public enum PointerAcceleration: Sendable, Equatable {
    case off
    case curve(Double)
}

public struct PointerDevice: Sendable, Equatable {
    public var match: DeviceMatch
    public var pointer: PointerConfig
}

/// How `navigate.back`/`navigate.forward` reach each app (bundle id prefixes).
public struct NavigateConfig: Sendable, Equatable {
    /// Extra apps that get a trackpad swipe.
    public var swipe: [String] = []
    /// Apps that get mouse buttons 4/5, even if they'd get a swipe by default.
    public var buttons: [String] = []
}

// MARK: - Window manager (wm.toml, AeroSpace's format)

/// wm.toml uses AeroSpace's keys for everything about windows; app-level settings (login item,
/// reloading, keyboard layout) belong to HyperSpace and aren't in it. An empty file (or one
/// with only comments) leaves the window manager off.
public struct WMConfig: Sendable, Equatable {
    /// True when the file sets nothing: the window manager stays off.
    public var isEmpty = true
    public var onFocusChanged: [String] = []
    public var onFocusedMonitorChanged: [String] = []
    public var onModeChanged: [String] = []
    /// tiles | accordion
    public var defaultRootContainerLayout = "tiles"
    /// horizontal | vertical | auto
    public var defaultRootContainerOrientation = "auto"
    public var automaticallyUnhideMacosHiddenApps = false
    public var accordionPadding = 30
    public var persistentWorkspaces: [String]?
    /// A process (argv) run when the focused workspace changes.
    public var execOnWorkspaceChange: [String] = []
    /// Mode name -> hotkey -> commands.
    public var modes: [String: [String: [String]]] = [:]
    public var gaps = GapsConfig()
    public var focusFollowsMouse = false
    /// Workspace name -> monitor patterns.
    public var workspaceToMonitorForceAssignment: [String: [String]] = [:]
    public var onWindowDetected: [WindowDetectedRule] = []

    public init() {}
}

/// One gap: a number, or per-monitor values `[{ monitor.main = 16 }, { monitor."dell" = 32 }, 24]`.
public struct GapValue: Sendable, Equatable {
    public var perMonitor: [(pattern: String, value: Int)] = []
    public var fallback = 0

    public init(_ value: Int = 0) { fallback = value }

    public static func == (a: GapValue, b: GapValue) -> Bool {
        a.fallback == b.fallback && a.perMonitor.map(\.pattern) == b.perMonitor.map(\.pattern)
            && a.perMonitor.map(\.value) == b.perMonitor.map(\.value)
    }
}

public struct GapsConfig: Sendable, Equatable {
    public var innerHorizontal = GapValue(), innerVertical = GapValue()
    public var outerLeft = GapValue(), outerBottom = GapValue(), outerTop = GapValue(), outerRight = GapValue()

    public init() {}
}

/// `[[on-window-detected]]`: `if` (a command such as `test %{app-bundle-id} = ...`, or the
/// legacy `if.app-id = ...` table), `run`, `check-further-callbacks`.
public struct WindowDetectedRule: Sendable, Equatable {
    public enum Condition: Sendable, Equatable {
        case script(String)
        case legacy(appID: String?, appNameRegex: String?, windowTitleRegex: String?, workspace: String?, duringStartup: Bool?)
    }

    public var condition: Condition?
    public var checkFurtherCallbacks = false
    public var run: [String] = []
}

// MARK: - Decoding
// Every table rejects unknown keys, so a typo is an error instead of a silent no-op.

extension KeyboardConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case map, app, device, capslock, layer, double, doubleTapMs = "double_tap_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        map = try c.decode(.map, default: [:])
        app = try c.decode(.app, default: [])
        device = try c.decode(.device, default: [])
        capslock = try c.decodeIfPresent(LayerConfig.self, forKey: .capslock)
        layer = try c.decode(.layer, default: [:])
        double = try c.decode(.double, default: [:])
        doubleTapMs = try c.decode(.doubleTapMs, default: 300)
    }
}

extension LayerConfig: Decodable {
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
    enum CodingKeys: String, CodingKey, CaseIterable { case name, vendor, product, map }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        match = try DeviceMatch(c)
        map = try c.decode(.map, default: [:])
    }
}

extension DeviceMatch {
    /// Reads `name`, `vendor` and `product` from a table that has them.
    init<K: CodingKey & CaseIterable>(_ c: KeyedDecodingContainer<K>) throws {
        func key(_ name: String) -> K { K.allCases.first { $0.stringValue == name }! }
        name = try c.decodeIfPresent(String.self, forKey: key("name"))
        vendor = try c.decodeIfPresent(Int.self, forKey: key("vendor"))
        product = try c.decodeIfPresent(Int.self, forKey: key("product"))
    }
}

extension MouseConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case buttons, app, hold, scroll, pointer, device, navigate }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        buttons = try c.decode(.buttons, default: [:])
        app = try c.decode(.app, default: [AppButtons]()).map(\.app)
        hold = try c.decode(.hold, default: [:])
        scroll = try c.decodeIfPresent(ScrollConfig.self, forKey: .scroll)
        pointer = try c.decode(.pointer, default: PointerConfig())
        device = try c.decode(.device, default: [])
        navigate = try c.decode(.navigate, default: NavigateConfig())
    }
}

extension HoldConfig: Decodable {
    /// Keys are input names plus `distance`; names are checked by `MousePlan`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.anyTable()
        for key in c.allKeys {
            if key.stringValue == "distance" {
                distance = try c.decode(Int.self, forKey: key)
            } else {
                map[key.stringValue] = try c.decode(Action.self, forKey: key)
            }
        }
    }
}

extension ScrollConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case reverse, linear, lines, smooth, fast, fastFactor = "fast_factor"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        // `reverse = true` means both axes; a string picks one.
        if let both = try? c.decodeIfPresent(Bool.self, forKey: .reverse) {
            reverse = both ? .both : .none
        } else if let axes = try c.decodeIfPresent(String.self, forKey: .reverse) {
            guard let parsed = ScrollAxes(rawValue: axes) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [CodingKeys.reverse],
                                                        debugDescription: "use true, false, \"vertical\" or \"horizontal\""))
            }
            reverse = parsed
        }
        linear = try c.decode(.linear, default: false)
        lines = try c.decodeIfPresent(Int.self, forKey: .lines)
        smooth = try c.decode(.smooth, default: false)
        fast = try c.decodeIfPresent(String.self, forKey: .fast)
        fastFactor = try c.decodeNumber(.fastFactor) ?? 3
    }
}

extension PointerConfig: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case speed, acceleration }

    public init(from decoder: any Decoder) throws {
        self = try PointerConfig(try decoder.table(CodingKeys.self))
    }

    /// Reads `speed` and `acceleration` from a table that has them.
    init<K: CodingKey & CaseIterable>(_ c: KeyedDecodingContainer<K>) throws {
        func key(_ name: String) -> K { K.allCases.first { $0.stringValue == name }! }
        speed = try c.decodeNumber(key("speed"))
        // `acceleration = false` is off, `true` keeps the macOS curve, a number sets it.
        if let on = try? c.decodeIfPresent(Bool.self, forKey: key("acceleration")) {
            acceleration = on ? nil : .off
        } else {
            acceleration = try c.decodeNumber(key("acceleration")).map(PointerAcceleration.curve)
        }
    }
}

extension PointerDevice: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case name, vendor, product, speed, acceleration }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        match = try DeviceMatch(c)
        pointer = try PointerConfig(c)
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
    enum CodingKeys: String, CodingKey, CaseIterable {
        case onFocusChanged = "on-focus-changed"
        case onFocusedMonitorChanged = "on-focused-monitor-changed"
        case onModeChanged = "on-mode-changed"
        case rootLayout = "default-root-container-layout"
        case rootOrientation = "default-root-container-orientation"
        case unhide = "automatically-unhide-macos-hidden-apps"
        case accordionPadding = "accordion-padding"
        case persistentWorkspaces = "persistent-workspaces"
        case execOnWorkspaceChange = "exec-on-workspace-change"
        case mode
        case gaps
        case focusFollowsMouse = "focus-follows-mouse"
        case assignment = "workspace-to-monitor-force-assignment"
        case onWindowDetected = "on-window-detected"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        isEmpty = c.allKeys.isEmpty
        onFocusChanged = try c.decode(.onFocusChanged, default: Commands()).list
        onFocusedMonitorChanged = try c.decode(.onFocusedMonitorChanged, default: Commands()).list
        onModeChanged = try c.decode(.onModeChanged, default: Commands()).list
        defaultRootContainerLayout = try c.decode(.rootLayout, default: "tiles")
        defaultRootContainerOrientation = try c.decode(.rootOrientation, default: "auto")
        automaticallyUnhideMacosHiddenApps = try c.decode(.unhide, default: false)
        accordionPadding = try c.decode(.accordionPadding, default: 30)
        persistentWorkspaces = try c.decodeIfPresent([String].self, forKey: .persistentWorkspaces)
        execOnWorkspaceChange = try c.decode(.execOnWorkspaceChange, default: [])
        modes = try c.decode(.mode, default: [String: ModeTable]()).mapValues(\.bindings)
        gaps = try c.decode(.gaps, default: GapsTable()).gaps
        focusFollowsMouse = try c.decode(.focusFollowsMouse, default: FocusFollowsMouseTable()).enabled
        workspaceToMonitorForceAssignment = try c.decode(.assignment, default: [String: Patterns]()).mapValues(\.list)
        onWindowDetected = try c.decode(.onWindowDetected, default: [])
    }
}

/// A string or an array of strings (commands, monitor patterns).
private struct Commands: Decodable {
    var list: [String] = []

    init() {}

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            list = [single]
        } else {
            list = try [String](from: decoder)
        }
    }
}

private typealias Patterns = Commands

private struct ModeTable: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case binding }
    var bindings: [String: [String]] = [:]

    init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        bindings = try c.decode(.binding, default: [String: Commands]()).mapValues(\.list)
    }
}

private struct FocusFollowsMouseTable: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled }
    var enabled = false

    init() {}

    init(from decoder: any Decoder) throws {
        enabled = try decoder.table(CodingKeys.self).decode(.enabled, default: false)
    }
}

private struct GapsTable: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case inner, outer }
    enum InnerKeys: String, CodingKey, CaseIterable { case horizontal, vertical }
    enum OuterKeys: String, CodingKey, CaseIterable { case left, bottom, top, right }
    var gaps = GapsConfig()

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        if let inner = try c.decodeIfPresent(InnerTable.self, forKey: .inner) {
            gaps.innerHorizontal = inner.horizontal
            gaps.innerVertical = inner.vertical
        }
        if let outer = try c.decodeIfPresent(OuterTable.self, forKey: .outer) {
            gaps.outerLeft = outer.left
            gaps.outerBottom = outer.bottom
            gaps.outerTop = outer.top
            gaps.outerRight = outer.right
        }
    }

    struct InnerTable: Decodable {
        var horizontal = GapValue(), vertical = GapValue()
        init(from decoder: any Decoder) throws {
            let c = try decoder.table(InnerKeys.self)
            horizontal = try c.decode(.horizontal, default: GapValue())
            vertical = try c.decode(.vertical, default: GapValue())
        }
    }

    struct OuterTable: Decodable {
        var left = GapValue(), bottom = GapValue(), top = GapValue(), right = GapValue()
        init(from decoder: any Decoder) throws {
            let c = try decoder.table(OuterKeys.self)
            left = try c.decode(.left, default: GapValue())
            bottom = try c.decode(.bottom, default: GapValue())
            top = try c.decode(.top, default: GapValue())
            right = try c.decode(.right, default: GapValue())
        }
    }
}

extension GapValue: Decodable {
    /// `8`, or `[{ monitor.main = 16 }, { monitor."some-pattern" = 32 }, 24]`.
    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Int.self) {
            fallback = value
            return
        }
        for entry in try [Entry](from: decoder) {
            if let pattern = entry.pattern { perMonitor.append((pattern, entry.value)) } else { fallback = entry.value }
        }
    }

    /// One array element: a number (the default) or `{ monitor.<pattern> = <number> }`.
    private struct Entry: Decodable {
        enum CodingKeys: String, CodingKey, CaseIterable { case monitor }
        var pattern: String?
        var value = 0

        init(from decoder: any Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(Int.self) {
                self.value = value
                return
            }
            let monitors = try decoder.table(CodingKeys.self).decode([String: Int].self, forKey: .monitor)
            guard monitors.count == 1, let (pattern, value) = monitors.first else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "use { monitor.<pattern> = <number> }"))
            }
            self.pattern = pattern
            self.value = value
        }
    }
}

extension WindowDetectedRule: Decodable {
    enum CodingKeys: String, CodingKey, CaseIterable { case `if`, checkFurtherCallbacks = "check-further-callbacks", run }

    /// The legacy `if.app-id = ...` table.
    private struct LegacyCondition: Decodable {
        enum CodingKeys: String, CodingKey, CaseIterable {
            case appID = "app-id", appName = "app-name-regex-substring", title = "window-title-regex-substring"
            case workspace, duringStartup = "during-aerospace-startup"
        }
        let condition: Condition

        init(from decoder: any Decoder) throws {
            let c = try decoder.table(CodingKeys.self)
            condition = .legacy(appID: try c.decodeIfPresent(String.self, forKey: .appID),
                                appNameRegex: try c.decodeIfPresent(String.self, forKey: .appName),
                                windowTitleRegex: try c.decodeIfPresent(String.self, forKey: .title),
                                workspace: try c.decodeIfPresent(String.self, forKey: .workspace),
                                duringStartup: try c.decodeIfPresent(Bool.self, forKey: .duringStartup))
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.table(CodingKeys.self)
        if let script = try? c.decodeIfPresent(String.self, forKey: .if) {
            condition = .script(script)
        } else if let legacy = try c.decodeIfPresent(LegacyCondition.self, forKey: .if) {
            condition = legacy.condition
        }
        checkFurtherCallbacks = try c.decode(.checkFurtherCallbacks, default: false)
        guard c.contains(.run) else {
            throw DecodingError.keyNotFound(CodingKeys.run, .init(codingPath: c.codingPath, debugDescription: "'run' is mandatory"))
        }
        run = try c.decode(Commands.self, forKey: .run).list
    }
}
