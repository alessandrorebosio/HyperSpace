/// Keyboard and mouse plans together: everything the input layer needs.
public struct InputPlan: Sendable, Equatable {
    public var keyboard = KeyboardPlan()
    public var mouse = MousePlan()

    public var needsEventTap: Bool { keyboard.needsEventTap || mouse.needsEventTap }

    public init(keyboard: KeyboardPlan = KeyboardPlan(), mouse: MousePlan = MousePlan()) {
        self.keyboard = keyboard
        self.mouse = mouse
    }

    public init(_ config: Config) throws(InvalidConfig) {
        keyboard = try KeyboardPlan(config.keyboard)
        mouse = try MousePlan(config.mouse)
    }

    /// The tables the event tap uses while `bundleID` is the frontmost app.
    public func tables(forApp bundleID: String?) -> ActiveTables {
        func pick(_ apps: [String: OutputTable], _ base: OutputTable) -> OutputTable {
            bundleID.flatMap { apps[$0] } ?? base
        }
        return ActiveTables(
            keys: pick(keyboard.apps, keyboard.map),
            layer: keyboard.layer,
            layerMap: keyboard.layer.map { pick($0.apps, $0.base) } ?? .keys,
            buttons: pick(mouse.apps, mouse.buttons),
            scroll: mouse.scroll,
            navigation: mouse.navigation
        )
    }
}

/// Lookup tables resolved for the frontmost app, made by `InputPlan.tables(forApp:)`.
/// Immutable: the tap swaps whole snapshots.
public struct ActiveTables: Sendable, Equatable {
    public var keys = OutputTable.keys
    public var layer: Layer?
    public var layerMap = OutputTable.keys
    public var buttons = OutputTable.buttons
    public var scroll: ScrollConfig?
    public var navigation = NavigationRules()
}
