import Foundation

enum Direction: String {
    case left, right, up, down
}

enum LayoutKind: String, CaseIterable {
    case tall, wide, columns, monocle
}

/// Everything a key binding or mouse button can trigger.
/// Parsed once at config load, so the event tap never touches strings.
enum Action {
    case focus(Direction)
    case swap(Direction)
    case swapMaster
    case setLayout(LayoutKind)
    case nextLayout
    case adjustRatio(Double)
    case toggleFloat
    case toggleTiling
    case retile
    case moveToNextDisplay
    case focusNextDisplay
    /// 0-based workspace index.
    case workspace(Int)
    /// Back to the previously active workspace.
    case workspaceBackAndForth
    case moveToWorkspace(Int)
    /// Grow (positive) or shrink the focused window by points.
    case resize(width: Bool, delta: CGFloat)
    case launch(String)
    case shell(String)
    case sendKey(KeyCombo)
    case reload
    /// Does nothing: binding it disables a mouse button or key.
    case none
    /// History back/forward with the shortcut of the frontmost app.
    case navigate(back: Bool)
    case system(SystemAction)
    case media(MediaKey)
    /// A left click at the pointer with modifiers (e.g. ⌘-click opens a link in a new tab).
    case click(Modifiers)

    static func parse(_ text: String) throws -> Action {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        func direction() throws -> Direction {
            guard let dir = Direction(rawValue: arg.lowercased()) else {
                throw ConfigError("expected left/right/up/down in '\(text)'")
            }
            return dir
        }
        func workspaceIndex() throws -> Int {
            guard let number = Int(arg), number >= 1 else { throw ConfigError("expected a workspace number in '\(text)'") }
            return number - 1
        }
        func nonEmpty() throws -> String {
            guard !arg.isEmpty else { throw ConfigError("missing argument in '\(text)'") }
            return arg
        }

        switch verb {
        case "focus": return .focus(try direction())
        case "swap": return arg.lowercased() == "master" ? .swapMaster : .swap(try direction())
        case "layout":
            if arg.lowercased() == "next" { return .nextLayout }
            guard let kind = LayoutKind(rawValue: arg.lowercased()) else { throw ConfigError("unknown layout in '\(text)'") }
            return .setLayout(kind)
        case "ratio":
            guard let delta = Double(arg) else { throw ConfigError("expected a number in '\(text)'") }
            return .adjustRatio(delta)
        case "float": return .toggleFloat
        case "tiling": return .toggleTiling
        case "retile": return .retile
        case "display": return .moveToNextDisplay
        case "focus-display": return .focusNextDisplay
        case "workspace":
            if arg.lowercased() == "back-and-forth" { return .workspaceBackAndForth }
            return .workspace(try workspaceIndex())
        case "move-to-workspace": return .moveToWorkspace(try workspaceIndex())
        case "resize":
            let parts = arg.lowercased().split(separator: " ")
            guard parts.count == 2, parts[0] == "width" || parts[0] == "height", let delta = Double(parts[1]) else {
                throw ConfigError("expected 'resize width|height <points>' in '\(text)'")
            }
            return .resize(width: parts[0] == "width", delta: CGFloat(delta))
        case "launch": return .launch(try nonEmpty())
        case "shell": return .shell(try nonEmpty())
        case "key": return .sendKey(try KeyCombo.parse(try nonEmpty()))
        case "reload": return .reload
        case "none": return .none
        case "navigate":
            switch arg.lowercased() {
            case "back": return .navigate(back: true)
            case "forward": return .navigate(back: false)
            default: throw ConfigError("expected back/forward in '\(text)'")
            }
        case "system":
            guard let action = SystemAction(rawValue: arg.lowercased()) else { throw ConfigError("unknown system action in '\(text)'") }
            return .system(action)
        case "media":
            guard let key = MediaKey(rawValue: arg.lowercased()) else { throw ConfigError("unknown media key in '\(text)'") }
            return .media(key)
        case "click": return .click(try Modifiers.parse(arg))
        default: throw ConfigError("unknown action '\(text)'")
        }
    }
}
