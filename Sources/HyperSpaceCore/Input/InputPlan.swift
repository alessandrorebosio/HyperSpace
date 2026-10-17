/// Keyboard and mouse plans together: everything the input layer needs.
public struct InputPlan: Sendable, Equatable {
    public var keyboard = KeyboardPlan()
    public var mouse = MousePlan()
    /// Window manager hotkeys per binding mode (wm.toml `[mode.<name>.binding]`).
    public var hotkeys: [String: OutputTable] = [:]
    /// wm.toml `show-bindings-on-hold`, in the main mode only.
    public var holdHint: HoldHint?

    public var needsEventTap: Bool { keyboard.needsEventTap || mouse.needsEventTap || !hotkeys.isEmpty }

    public init(keyboard: KeyboardPlan = KeyboardPlan(), mouse: MousePlan = MousePlan()) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    public init(_ config: Config) throws(InvalidConfig) {
        keyboard = try KeyboardPlan(config.keyboard)
        mouse = try MousePlan(config.mouse)
        if !config.wm.isEmpty {
            let wm = try WMSettings(config.wm)
            hotkeys = wm.hotkeys
            holdHint = wm.bindingsOnHold?.hint
        }
    }

    /// The tables the event tap uses while `bundleID` is the frontmost app and `mode` is the
    /// window manager's binding mode.
    public func tables(forApp bundleID: String?, mode: String = "main") -> ActiveTables {
        let hotkeys = self.hotkeys[mode]
        func pick(_ apps: [String: OutputTable], _ base: OutputTable) -> OutputTable {
            bundleID.flatMap { apps[$0] } ?? base
        }
        return ActiveTables(
            keys: pick(keyboard.apps, keyboard.map),
            layers: keyboard.layers,
            layerMaps: keyboard.layers.map { pick($0.apps, $0.base) },
            double: keyboard.double,
            doubleTapNs: keyboard.doubleTapNs,
            hotkeys: hotkeys ?? .hotkeys,
            hasHotkeys: hotkeys.map { !$0.isEmpty } ?? false,
            buttons: pick(mouse.apps, mouse.buttons),
            holds: mouse.holds,
            scroll: mouse.scroll,
            navigation: mouse.navigation,
            holdHint: mode == "main" ? holdHint : nil
        )
    }
}

/// Lookup tables resolved for the frontmost app, made by `InputPlan.tables(forApp:)`.
/// Immutable: the tap swaps whole snapshots.
public struct ActiveTables: Sendable, Equatable {
    public var keys = OutputTable.keys
    public var layers: [Layer] = []
    /// `layers[i]`'s map for the frontmost app.
    public var layerMaps: [OutputTable] = []
    public var double = OutputTable.keys
    public var doubleTapNs: UInt64 = 0
    public var hotkeys = OutputTable.hotkeys
    /// Precomputed: checking an empty 2048-entry table on every key would be wasted work.
    public var hasHotkeys = false
    public var buttons = OutputTable.buttons
    public var holds: [HoldPlan?] = []
    public var scroll: ScrollPlan?
    public var navigation = NavigationRules()
    public var holdHint: HoldHint?
}
