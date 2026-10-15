/// Which windows the window manager takes and which of those float, from what
/// Accessibility says about a window when it appears.
public enum WMWindowKind {
    /// `nil`: not a window to manage (popups, menus, tooltips...). `true`: float it.
    /// `false`: tile it.
    ///
    /// Like AeroSpace, standard windows are tiled, but these float:
    /// - dialogs and panels (inspectors, color pickers, alerts): they belong over a window;
    /// - windows of a fixed size (calculators, About boxes): they can't take a tile;
    /// - windows whose full screen button is missing or off (settings panes), except for apps
    ///   that hide their title bar and so have no such button at all.
    public static func floating(subrole: String?, resizable: Bool, fullscreenButton: Bool, bundleID: String?) -> Bool? {
        switch subrole {
        case "AXStandardWindow":
            if !resizable { return true }
            if let id = bundleID, tiledWithoutFullscreenButton.contains(where: { id.hasPrefix($0) }) { return false }
            return !fullscreenButton
        case "AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow":
            return true
        default:
            return nil
        }
    }

    private static let tiledWithoutFullscreenButton = [
        "com.microsoft.VSCode", "com.google.Chrome", "com.apple.ActivityMonitor", "org.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "com.googlecode.iterm2", "org.gnu.Emacs", "com.mitchellh.ghostty", "com.valvesoftware.steam",
    ]
}
