import CoreGraphics

/// Words the settings pages and the menu bar share: one feature reads the same wherever it shows.
enum Wording {
    /// Where the Accessibility permission is granted, as System Settings names it.
    static let accessibilityPane = "Privacy & Security → Accessibility"
    static let openSystemSettings = "Open System Settings…"
    static let editConfig = "Edit Config…"
    static let otherApp = "Other App…"
    /// A key cap that is recording.
    static let pressKeys = "Press keys…"
    static let anyApp = "Any app"

    /// What tiling does, on and off: the menu bar's Tiling item and the Tiling page.
    static let tilingOn = "Windows are arranged on each display"
    static let tilingOff = "Windows stay where you put them"

    /// The symbol of every warning and error.
    static let warningSymbol = "exclamationmark.triangle.fill"
}

/// The widths and gaps the settings pages repeat.
enum Metrics {
    /// Between a row's label and its control, and the least gap a `Spacer` keeps there.
    static let rowGap: CGFloat = 12
    /// Between the parts of a rule row (caps, arrow, menu).
    static let ruleSpacing: CGFloat = 8
    /// The least width of a remap's key caps.
    static let keyCapWidth: CGFloat = 96
    /// The least width of a mouse button's cap, and of its action's.
    static let buttonCapWidth: CGFloat = 140
    static let actionCapWidth: CGFloat = 110
    /// The fixed width of a shortcut cap, so the columns of a `ShortcutGrid` line up.
    static let shortcutCapWidth: CGFloat = 112
    /// A workspace's name field in the grid, and the most it gets on its own line.
    static let nameWidth: CGFloat = 120
    static let nameMaxWidth: CGFloat = 160
    /// The most a workspace's display menu gets: a long name is truncated.
    static let displayMenuWidth: CGFloat = 160
    /// The least width of the app column of the scratchpad grid.
    static let appColumnWidth: CGFloat = 100
}

extension LayoutKind {
    /// The layout's name on the Tiling page.
    var displayName: String {
        switch self {
        case .tall: return "Tall"
        case .wide: return "Wide"
        case .columns: return "Columns"
        case .monocle: return "Monocle"
        case .accordion: return "Accordion"
        }
    }
}
