/// Keyboard state machine for the event tap. Pure logic, no CoreGraphics, so it can be tested.
/// Runs on the input thread only; `tables` are swapped in from the main thread between events.
public struct KeyEngine: Sendable {
    public enum Decision: Sendable, Equatable {
        /// Deliver the event unchanged.
        case pass
        /// Swallow the event.
        case drop
        /// Deliver the event with another key code and these modifiers added to the physical ones.
        case rewrite(Combo)
        /// Swallow the event and perform the output once (a key is sent as a full press).
        case emit(Output)
    }

    private var layerDown = false
    private var layerUsed = false
    private var layerDownAt: UInt64 = 0
    /// Output chosen when a key went down, so its repeats and release match even if the layer
    /// or the frontmost app changed meanwhile. A fixed table: no allocations on the hot path.
    private var inFlight = OutputTable.keys

    public init() {}

    /// True while the Caps Lock layer trigger is held.
    public var isLayerHeld: Bool { layerDown }

    /// - Parameter now: monotonic time in nanoseconds.
    public mutating func handle(code: UInt16, down: Bool, isRepeat: Bool, now: UInt64,
                                tables: ActiveTables) -> Decision {
        if let layer = tables.layer, code == Layer.trigger.code {
            return handleTrigger(down: down, isRepeat: isRepeat, now: now, layer: layer)
        }
        let index = Int(code)

        // Repeats and releases follow the press; outputs other than keys fire only once.
        if !down || isRepeat {
            guard let output = inFlight[index] else { return .pass }
            if !down { inFlight[index] = nil }
            if case let .key(combo) = output { return .rewrite(combo) }
            return .drop
        }

        var output: Output?
        if layerDown, let layer = tables.layer {
            layerUsed = true
            output = tables.layerMap[index]
            if output == nil, !layer.hold.isEmpty, let key = KeyNames.key(code: code) {
                output = .key(Combo(key: key, modifiers: layer.hold)) // e.g. Caps + t = ⇧⌃⌥t
            }
        }
        inFlight[index] = output ?? tables.keys[index]
        switch inFlight[index] {
        case nil: return .pass
        case let .key(combo): return .rewrite(combo)
        case .drop: return .drop
        case let output?: return .emit(output)
        }
    }

    private mutating func handleTrigger(down: Bool, isRepeat: Bool, now: UInt64, layer: Layer) -> Decision {
        if down {
            if !isRepeat, !layerDown {
                layerDown = true
                layerUsed = false
                layerDownAt = now
            }
            return .drop // the trigger itself never reaches apps
        }
        defer { layerDown = false }
        guard layerDown, !layerUsed, now &- layerDownAt <= layer.tapTimeoutNs,
              let alone = layer.alone, alone != .drop else { return .drop }
        return .emit(alone)
    }
}
