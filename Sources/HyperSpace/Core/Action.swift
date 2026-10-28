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
    case launch(String)
    case shell(String)
    case sendKey(KeyCombo)
    case reload
    /// Does nothing: binding it disables a mouse button or key.
    case none

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
        case "launch": return .launch(try nonEmpty())
        case "shell": return .shell(try nonEmpty())
        case "key": return .sendKey(try KeyCombo.parse(try nonEmpty()))
        case "reload": return .reload
        case "none": return .none
        default: throw ConfigError("unknown action '\(text)'")
        }
    }
}
