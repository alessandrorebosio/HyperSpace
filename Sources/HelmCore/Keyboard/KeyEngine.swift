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
    /// Output chosen when a key went down, so its repeat and release match even if the
    /// layer or the frontmost app changed in the meantime.
    /// Fixed-size table instead of a dictionary: no allocations on the hot path.
    private var inFlight = KeyTable()

    public init() {}

    /// - Parameter now: monotonic time in nanoseconds.
    public mutating func handle(code: UInt16, down: Bool, isRepeat: Bool, now: UInt64,
                                tables: ActiveTables) -> Decision {
        if let layer = tables.layer, code == layer.trigger {
            return handleTrigger(down: down, isRepeat: isRepeat, now: now, layer: layer)
        }

        if !down {
            guard let output = inFlight[code] else { return .pass }
            inFlight[code] = nil
            if case let .key(combo) = output { return .rewrite(combo) }
            return .drop
        }

        if isRepeat {
            guard let output = inFlight[code] else { return .pass }
            if case let .key(combo) = output { return .rewrite(combo) }
            return .drop // shell/wm/drop fire once, never on repeat
        }

        var output: Output?
        if layerDown, let layer = tables.layer {
            layerUsed = true
            output = layer.map[code]
        }
        if output == nil { output = tables.simple[code] }
        guard let output else {
            inFlight[code] = nil
            return .pass
        }
        inFlight[code] = output
        switch output {
        case let .key(combo): return .rewrite(combo)
        case .drop: return .drop
        case .shell, .wm: return .emit(output)
        }
    }

    private mutating func handleTrigger(down: Bool, isRepeat: Bool, now: UInt64,
                                        layer: ActiveTables.ActiveLayer) -> Decision {
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
