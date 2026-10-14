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
        ActiveTables(
            simple: keyboard.simple,
            layer: keyboard.layer,
            layerMap: keyboard.layer.map { layer in bundleID.flatMap { layer.apps[$0] } ?? layer.base } ?? .keys,
            buttons: bundleID.flatMap { mouse.apps[$0] } ?? mouse.buttons,
            scroll: mouse.scroll
        )
    }
}

/// Lookup tables resolved for the frontmost app. Immutable: the tap swaps whole snapshots.
public struct ActiveTables: Sendable, Equatable {
    public var simple = OutputTable.keys
    public var layer: Layer?
    public var layerMap = OutputTable.keys
    public var buttons = OutputTable.buttons
    public var scroll: ScrollConfig?

    public init() {}

    init(simple: OutputTable, layer: Layer?, layerMap: OutputTable, buttons: OutputTable, scroll: ScrollConfig?) {
        self.simple = simple
        self.layer = layer
        self.layerMap = layerMap
        self.buttons = buttons
        self.scroll = scroll
    }
}
