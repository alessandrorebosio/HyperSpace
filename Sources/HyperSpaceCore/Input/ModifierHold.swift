/// `show-bindings-on-hold`: which modifiers, held alone for how long.
public struct HoldHint: Sendable, Equatable {
    public var modifiers: Modifiers
    public var delayNs: UInt64

    public init(modifiers: Modifiers, delayNs: UInt64) {
        self.modifiers = modifiers
        self.delayNs = delayNs
    }
}

/// Whether exactly the hint's modifiers are held with no key pressed since: the tap arms
/// a timer on `.arm` and shows the bindings when it fires, and hides them on `.disarm`.
/// A key pressed spoils the hold until the modifiers change. Pure logic, for tests.
public struct ModifierHold: Sendable {
    public enum Change: Sendable, Equatable { case none, arm, disarm }

    private var armed = false
    private var spoiled = false
    private var held: Modifiers = []

    public init() {}

    /// - Parameters:
    ///   - held: the modifiers held now, physical and from a layer key.
    ///   - keyPressed: a key (not a modifier or layer key, not a repeat) went down.
    public mutating func update(held: Modifiers, keyPressed: Bool, target: Modifiers?) -> Change {
        if held != self.held {
            self.held = held
            spoiled = false
        }
        if keyPressed { spoiled = true }
        let wanted = target == held && !spoiled
        guard wanted != armed else { return .none }
        armed = wanted
        return wanted ? .arm : .disarm
    }
}
