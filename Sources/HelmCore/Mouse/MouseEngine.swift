/// Mouse button state machine for the event tap. Pure logic, runs on the input thread only.
public struct MouseEngine: Sendable {
    public enum Decision: Sendable, Equatable {
        case pass
        case drop
        /// Swallow the event and perform the output once.
        case emit(Output)
    }

    /// Output chosen when a button went down, so its release matches.
    private var inFlight = ButtonTable()

    public init() {}

    public mutating func button(_ number: Int, down: Bool, tables: ActiveTables) -> Decision {
        if !down {
            guard inFlight[number] != nil else { return .pass }
            inFlight[number] = nil
            return .drop
        }
        guard let output = tables.buttons[number] else {
            inFlight[number] = nil
            return .pass
        }
        inFlight[number] = output
        return output == .drop ? .drop : .emit(output)
    }

    /// While a remapped button is held, its drag events must become plain moves,
    /// otherwise apps would see a drag without a button press.
    public func isSwallowed(_ number: Int) -> Bool {
        inFlight[number] != nil
    }
}
