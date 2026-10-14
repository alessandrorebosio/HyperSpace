import Foundation
import TOMLDecoder

public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String

    public var description: String { "\(path): \(message)" }
}

public enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/helm/helm.toml`, falling back to `~/.config/helm/helm.toml`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "helm/helm.toml")
    }

    /// Loads the config. A missing file is not an error: it means every feature is off.
    public static func load(from url: URL = defaultURL) -> Result<Config, ConfigError> {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return .success(Config())
        } catch {
            return .failure(ConfigError(path: url.path, message: error.localizedDescription))
        }
        return parse(text, path: url.path)
    }

    public static func parse(_ text: String, path: String = "helm.toml") -> Result<Config, ConfigError> {
        do {
            let config = try TOMLDecoder().decode(Config.self, from: text)
            _ = try InputPlan(config) // validates key names, combos and mouse inputs
            return .success(config)
        } catch let error as InvalidConfig {
            return .failure(ConfigError(path: path, message: error.message))
        } catch let error as DecodingError {
            return .failure(ConfigError(path: path, message: describe(error)))
        } catch {
            return .failure(ConfigError(path: path, message: "\(error)"))
        }
    }

    /// Writes a commented starter config if none exists yet. Returns the config URL.
    @discardableResult
    public static func createTemplateIfMissing(at url: URL = defaultURL) throws -> URL {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try template.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Turns a DecodingError into "keyboard.capslock.alone: <reason>".
    static func describe(_ error: DecodingError) -> String {
        func path(_ keys: [any CodingKey]) -> String {
            keys.isEmpty ? "(top level)" : keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case let .typeMismatch(type, ctx):
            return "\(path(ctx.codingPath)): expected \(typeName(type))"
        case let .valueNotFound(type, ctx):
            return "\(path(ctx.codingPath)): missing \(typeName(type))"
        case let .keyNotFound(key, ctx):
            return "\(path(ctx.codingPath + [key])): required key is missing"
        case let .dataCorrupted(ctx):
            return "\(path(ctx.codingPath)): \(ctx.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: "a string"
        case is Int.Type: "an integer"
        case is Bool.Type: "true or false"
        default: "\(type)".contains("Dictionary") ? "a table" : "\(type)".contains("Array") ? "an array" : "\(type)"
        }
    }

    public static let template = """
    # Helm configuration. Saved changes are applied immediately.
    # Remapped keys and buttons only do what is mapped here; everything else is untouched.

    # ── Keyboard ─────────────────────────────────────────────
    # Keys:      a...z, 0...9, f1...f20, escape, tab, space, return, backspace, delete.forward,
    #            arrow.left/.right/.up/.down, home, end, page.up, page.down, capslock,
    #            shift.left/.right, control.left/.right, option.left/.right, command.left/.right.
    #            Names are US key positions: symbol keys (bracket.open, minus...) may be
    #            different characters on other layouts.
    # Modifiers: shift, ctrl, opt, cmd, fn, joined with "-" (e.g. "cmd-shift-k").
    # Actions:   "arrow.left" / "cmd-arrow.left"  a key or combo
    #            { shell = "open -a Safari" }     run a shell command
    #            "none"                           do nothing
    #            "passthrough"                    keep the normal behavior (for app exceptions)

    # Simple remaps, always active. key -> key works everywhere, even in password fields;
    # key -> combo needs Helm running. "device" limits a remap to one keyboard.
    # [keyboard]
    # simple = [
    #   { from = "command.right", to = "option.right" },
    #   { from = "f1", to = "cmd-space" },
    # ]

    # Caps Lock. Once this section exists, Caps Lock no longer toggles caps lock.
    # [keyboard.capslock]
    # hold = "shift-ctrl-opt"     # while held, Caps Lock acts as these modifiers
    # alone = "escape"            # action when tapped alone (default: nothing)
    # tap_timeout_ms = 200        # held longer than this = not a tap, "alone" doesn't fire

    # Caps + key overrides: listed keys do this instead of getting the modifiers above.
    # [keyboard.capslock.map]
    # h = "arrow.left"
    # j = "arrow.down"
    # k = "arrow.up"
    # l = "arrow.right"

    # Per-app Caps + key overrides.
    # [[keyboard.capslock.app]]
    # bundle_id = "com.microsoft.VSCode"
    # map = { d = "cmd-shift-k" }

    # ── Mouse ────────────────────────────────────────────────
    # Buttons: button1 = right, button2 (or middle) = wheel click,
    #          button3 (or back) / button4 (or forward) = side buttons, button5...31 = extra.
    #          The left button can't be remapped.
    # Actions: "navigate.back" / "navigate.forward"  back/forward in every app
    #          "cmd-w"                                a key or combo (US key positions)
    #          { shell = "open -a Safari" }           run a shell command
    #          "none"                                 disable the button
    #          "passthrough"                          keep the normal behavior (for app exceptions)
    # [mouse.buttons]
    # button3 = "navigate.back"     # side button: back
    # button4 = "navigate.forward"  # side button: forward
    # middle = "cmd-w"              # wheel click: close tab

    # Per-app exceptions: these buttons behave differently in one app.
    # [[mouse.app]]
    # bundle_id = "com.google.Chrome"
    # buttons = { button3 = "passthrough", button4 = "passthrough" }

    # Wheel scrolling only; trackpads and Magic Mouse are never touched.
    # [mouse.scroll]
    # reverse = true                # invert the wheel direction
    # linear = true                 # same distance per notch, no acceleration
    # lines = 3                     # lines per notch when linear (1-20)

    # ── Window manager ───────────────────────────────────────
    # [wm]
    # enabled = true

    """
}
