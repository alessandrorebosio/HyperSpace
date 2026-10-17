/// Keyboard state machine for the event tap. Pure logic, no CoreGraphics, so it can be tested.
/// Runs on the input thread only; `tables` are swapped in from the main thread between events.
///
/// Per key event it decides between passing the event, dropping it, rewriting its key code
/// and modifiers in place (cheapest: no new event), or emitting an output instead.
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
        /// Swallow the event and press a held output (`hold = true` clicks).
        case down(Output)
        /// Swallow the event and release a held output.
        case up(Output)
    }

    // Layer state: index into `tables.layers` of the layer key that is down.
    private var layer: Int?
    private var layerUsed = false
    private var layerDownAt: UInt64 = 0
    /// Keys pressed while a permissive layer is undecided (tap or hold?), not yet sent.
    private var pending: [UInt16] = []

    /// Output chosen when a key went down, so its repeats and release match even if the layer
    /// or the frontmost app changed meanwhile. A fixed table: no allocations on the hot path.
    private var inFlight = OutputTable.keys

    // Double tap state.
    private var lastTap: UInt16?
    private var lastTapAt: UInt64 = 0
    private var modifierDown: UInt16?
    private var modifierDownAt: UInt64 = 0
    private var modifierClean = false

    public init() {
        pending.reserveCapacity(8)
    }

    /// True while a layer key is held.
    public var isLayerHeld: Bool { layer != nil }

    /// The modifiers the held layer key adds (`hold = "shift-ctrl-opt"`), none without one.
    public func layerModifiers(_ tables: ActiveTables) -> Modifiers {
        layer.map { tables.layers[$0].hold } ?? []
    }

    /// An output to perform before applying the decision just returned: the keys a permissive
    /// layer held back, once it turns out to be a hold. The tap reads it after every event.
    public private(set) var emitBefore: Output?

    public mutating func takeEmitBefore() -> Output? {
        defer { emitBefore = nil }
        return emitBefore
    }

    /// - Parameters:
    ///   - modifiers: the modifiers physically held (for hotkeys).
    ///   - now: monotonic time in nanoseconds.
    public mutating func handle(code: UInt16, down: Bool, isRepeat: Bool, modifiers: Modifiers = [],
                                now: UInt64, tables: ActiveTables) -> Decision {
        if down, !isRepeat {
            modifierClean = false // a key between modifier press and release: not a tap
        }
        if let index = tables.layers.firstIndex(where: { $0.trigger == code }), layer == nil || layer == index {
            return handleLayerKey(index, down: down, isRepeat: isRepeat, now: now, tables: tables)
        }
        let index = Int(code)

        // A permissive layer is undecided while keys wait in `pending`.
        if let active = layer, !layerUsed, tables.layers[active].permissive {
            if down, !isRepeat, now &- layerDownAt <= tables.layers[active].tapTimeoutNs, pending.count < 8 {
                pending.append(code)
                return .drop
            }
            if !pending.isEmpty {
                // A pending key released or repeating, another key, or a long hold: it's a hold.
                let isPending = pending.contains(code)
                emitBefore = flushAsHold(tables: tables, releasing: !down && isPending ? code : nil)
                pending.removeAll()
                if isPending { return .drop } // its press was just sent with the others
            }
        }

        // Repeats and releases follow the press.
        if !down || isRepeat {
            guard let output = inFlight[index] else { return .pass }
            if !down { inFlight[index] = nil }
            switch output {
            case let .key(combo), let .held(.key(combo)): return .rewrite(combo)
            case let .repeating(inner) where isRepeat: return .emit(inner)
            case .held: return down ? .drop : .up(output)
            default: return .drop
            }
        }

        // Double tap of a normal key: the first press works as usual.
        if tables.double[index] != nil, layer == nil {
            if lastTap == code, now &- lastTapAt <= tables.doubleTapNs {
                lastTap = nil
                inFlight[index] = .drop
                return .emit(tables.double[index]!)
            }
            lastTap = code
            lastTapAt = now
        } else {
            lastTap = nil
        }

        if layer != nil { layerUsed = true }
        return press(index, modifiers: modifiers, tables: tables)
    }

    /// A modifier key changed (`flagsChanged`): returns the double-tap action to perform, if
    /// any. Modifier events always pass through.
    public mutating func modifier(code: UInt16, down: Bool, now: UInt64, tables: ActiveTables) -> Output? {
        let index = Int(code)
        guard let action = tables.double[index] else { return nil }
        if down {
            modifierDown = code
            modifierDownAt = now
            modifierClean = true
            return nil
        }
        defer { modifierDown = nil }
        guard modifierDown == code, modifierClean, now &- modifierDownAt <= tables.doubleTapNs else {
            lastTap = nil
            return nil
        }
        if lastTap == code, now &- lastTapAt <= tables.doubleTapNs {
            lastTap = nil
            return action
        }
        lastTap = code
        lastTapAt = now
        return nil
    }

    // MARK: - Private

    /// The decision for a key going down: layer map, then layer `hold` modifiers, then `[map]`.
    private mutating func press(_ index: Int, modifiers: Modifiers, tables: ActiveTables) -> Decision {
        inFlight[index] = layerOutput(index, tables: tables) ?? tables.keys[index]
        // Hotkeys match the key as apps would get it: after remapping, with the layer's
        // `hold` modifiers, so Caps + h can trigger a "shift-ctrl-opt-h" binding.
        if tables.hasHotkeys {
            let hotkey: (UInt16, Modifiers)? = switch inFlight[index] {
            case nil: (UInt16(index), modifiers)
            case let .key(combo)?: (combo.key.code, modifiers.union(combo.modifiers))
            default: nil
            }
            if let (code, mods) = hotkey, let output = tables.hotkeys[Hotkeys.index(code: code, modifiers: mods)] {
                inFlight[index] = .drop
                return .emit(output)
            }
        }
        switch inFlight[index] {
        case nil: return .pass
        case let .key(combo)?, let .held(.key(combo))?: return .rewrite(combo)
        case .drop?: return .drop
        case let .repeating(inner)?: return .emit(inner)
        case let output?:
            if case .held = output { return .down(output) }
            return .emit(output)
        }
    }

    private func layerOutput(_ index: Int, tables: ActiveTables) -> Output? {
        guard let active = layer else { return nil }
        if let output = tables.layerMaps[active][index] { return output }
        let hold = tables.layers[active].hold
        guard !hold.isEmpty, let key = KeyNames.key(code: UInt16(index)) else { return nil }
        return .key(Combo(key: key, modifiers: hold)) // e.g. Caps + t = ⇧⌃⌥t
    }

    /// Sends the pending keys as layer keys. Keys still held keep their output in `inFlight`
    /// so their repeats and release match.
    private mutating func flushAsHold(tables: ActiveTables, releasing: UInt16?) -> Output? {
        layerUsed = true
        var outputs: [Output] = []
        for code in pending {
            let index = Int(code)
            let output = layerOutput(index, tables: tables) ?? tables.keys[index] ?? KeyNames.key(code: code).map { .key(Combo(key: $0)) }
            inFlight[index] = code == releasing ? nil : output
            if let output, output != .drop { outputs.append(output) }
        }
        return outputs.isEmpty ? nil : outputs.count == 1 ? outputs[0] : .sequence(outputs)
    }

    private mutating func handleLayerKey(_ index: Int, down: Bool, isRepeat: Bool, now: UInt64,
                                         tables: ActiveTables) -> Decision {
        let layer = tables.layers[index]
        if down {
            if !isRepeat, self.layer == nil {
                self.layer = index
                layerUsed = false
                layerDownAt = now
                pending.removeAll()
            }
            return .drop // the layer key itself never reaches apps
        }
        defer {
            self.layer = nil
            pending.removeAll()
        }
        guard self.layer == index else { return .drop }
        let isTap = !layerUsed && now &- layerDownAt <= layer.tapTimeoutNs
        var outputs: [Output] = []
        if isTap, let alone = layer.alone, alone != .drop { outputs.append(alone) }
        if !pending.isEmpty {
            // Released before the pending keys: they were typed after the layer key.
            if isTap {
                for code in pending {
                    if let output = tables.keys[Int(code)] ?? KeyNames.key(code: code).map({ .key(Combo(key: $0)) }), output != .drop {
                        outputs.append(output)
                    }
                }
            } else if let flushed = flushAsHold(tables: tables, releasing: nil) {
                outputs.append(flushed)
            }
        }
        switch outputs.count {
        case 0: return .drop
        case 1: return .emit(outputs[0])
        default: return .emit(.sequence(outputs))
        }
    }
}
