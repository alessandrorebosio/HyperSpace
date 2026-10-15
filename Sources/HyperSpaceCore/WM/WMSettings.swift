/// wm.toml validated: everything the window manager needs besides the key bindings, which
/// are compiled into the keyboard's hotkey table (see `KeyboardPlan.hotkeys`).
public struct WMSettings: Sendable, Equatable {
    public var innerGap = 0.0
    public var outerGap = 0.0
    /// How much of each hidden child an accordion shows.
    public var accordionPadding = 30.0
    public var rules: [Rule] = []

    public struct Rule: Sendable, Equatable {
        /// Bundle id of the app.
        public var app: String
        public var floating: Bool?
        public var workspace: String?
    }

    public init() {}

    public func rule(for bundleID: String?) -> Rule? {
        guard let bundleID else { return nil }
        return rules.first { $0.app == bundleID }
    }

    public init(_ config: WMConfig) throws(InvalidConfig) {
        guard (0...200).contains(config.gaps.inner), (0...200).contains(config.gaps.outer) else {
            throw InvalidConfig(message: "gaps: must be between 0 and 200")
        }
        innerGap = Double(config.gaps.inner)
        outerGap = Double(config.gaps.outer)
        guard (0...500).contains(config.accordionPadding) else {
            throw InvalidConfig(message: "accordion_padding: must be between 0 and 500")
        }
        accordionPadding = Double(config.accordionPadding)
        for (i, rule) in config.rule.enumerated() {
            let floating: Bool? = switch rule.layout {
            case nil: nil
            case "floating": true
            case "tiling": false
            case let other?: throw InvalidConfig(message: "rule[\(i)].layout: '\(other)' isn't valid; use \"floating\" or \"tiling\"")
            }
            rules.append(Rule(app: rule.app, floating: floating, workspace: rule.workspace))
        }
    }
}
