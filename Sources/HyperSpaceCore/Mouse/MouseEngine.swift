/// Mouse state machine for the event tap: buttons, and the wheel and movement while a button
/// with a `[hold.<button>]` table is down. Pure logic, runs on the input thread only.
public struct MouseEngine: Sendable {
    public enum Decision: Sendable, Equatable {
        case pass
        case drop
        /// Swallow the event and perform the output once.
        case emit(Output)
        /// Swallow the event and press a held or repeating output.
        case down(Output)
        /// Swallow the event and release a held or repeating output.
        case up(Output)
        /// Swallow the event and send a normal click of this button (a hold button tapped
        /// without an action of its own).
        case click(Int)
    }

    /// Output chosen when a button went down, so its release matches.
    private var inFlight = OutputTable.buttons
    /// The hold button that is down, if any, and whether its hold table was used.
    private var holding: Int?
    private var holdUsed = false
    private var moveX = 0.0
    private var moveY = 0.0

    public init() {}

    public mutating func button(_ number: Int, down: Bool, tables: ActiveTables) -> Decision {
        if tables.holds.indices.contains(number), tables.holds[number] != nil {
            return holdButton(number, down: down, tables: tables)
        }
        if !down {
            guard let output = inFlight[number] else { return .pass }
            inFlight[number] = nil
            switch output {
            case .held, .repeating: return .up(output)
            default: return .drop
            }
        }
        inFlight[number] = tables.buttons[number]
        switch inFlight[number] {
        case nil: return .pass
        case .drop?: return .drop
        case let output? where Self.isHeld(output): return .down(output)
        case let output?: return .emit(output)
        }
    }

    /// The output a remapped button is holding down (to turn its drags into the right kind),
    /// `.drop` for a swallowed button, `nil` if the button isn't remapped.
    public func swallowed(_ number: Int) -> Output? {
        inFlight[number]
    }

    /// A wheel notch while a hold button is down: `dy` > 0 is up, `dx` > 0 is left.
    public mutating func scroll(dx: Int64, dy: Int64, tables: ActiveTables) -> Decision {
        guard let hold = activeHold(tables) else { return .pass }
        let direction: HoldPlan.Direction = dy > 0 ? .up : dy < 0 ? .down : dx > 0 ? .left : .right
        guard let output = hold.scroll[direction.rawValue] else { return .pass }
        holdUsed = true
        return output == .drop ? .drop : .emit(Self.once(output))
    }

    /// Mouse movement while a hold button is down: fires a `move.*` action every
    /// `distance` points, the dominant axis wins.
    public mutating func move(dx: Double, dy: Double, tables: ActiveTables) -> Output? {
        guard let hold = activeHold(tables), hold.hasMove else { return nil }
        moveX += dx
        moveY += dy
        let direction: HoldPlan.Direction
        if abs(moveX) >= hold.distance, abs(moveX) >= abs(moveY) {
            direction = moveX < 0 ? .left : .right
        } else if abs(moveY) >= hold.distance {
            direction = moveY < 0 ? .up : .down
        } else {
            return nil
        }
        moveX = 0
        moveY = 0
        guard let output = hold.move[direction.rawValue] else { return nil }
        holdUsed = true
        return Self.once(output)
    }

    // MARK: - Private

    /// A hold button swallows its press; on release it fires its own action (or a normal
    /// click) only if nothing in its hold table was used meanwhile.
    private mutating func holdButton(_ number: Int, down: Bool, tables: ActiveTables) -> Decision {
        if down {
            holding = number
            holdUsed = false
            moveX = 0
            moveY = 0
            inFlight[number] = .drop
            return .drop
        }
        inFlight[number] = nil
        guard holding == number else { return .drop }
        holding = nil
        if holdUsed { return .drop }
        guard let output = tables.buttons[number] else {
            return .click(number)
        }
        return output == .drop ? .drop : .emit(Self.once(output))
    }

    private func activeHold(_ tables: ActiveTables) -> HoldPlan? {
        guard let holding, tables.holds.indices.contains(holding) else { return nil }
        return tables.holds[holding]
    }

    private static func isHeld(_ output: Output) -> Bool {
        switch output {
        case .held, .repeating: true
        default: false
        }
    }

    /// Hold tables and taps fire once: there is no release to stop a repeat or a held press.
    private static func once(_ output: Output) -> Output {
        switch output {
        case let .held(inner), let .repeating(inner): inner
        default: output
        }
    }
}
