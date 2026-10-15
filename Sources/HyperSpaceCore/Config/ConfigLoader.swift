import Foundation
import TOMLDecoder

public struct ConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String

    public var description: String { "\(path): \(message)" }
}

/// One file of the config directory. Each is optional: a missing file means that feature is off.
public enum ConfigFile: String, CaseIterable, Sendable {
    case keyboard, mouse, wm

    public var fileName: String { "\(rawValue).toml" }
}

/// A section of `Config` stored in its own file.
protocol ConfigSection: Decodable {
    static var file: ConfigFile { get }
    static var empty: Self { get }
    /// Checks what decoding can't (key names, combos...), so a loaded section always applies.
    func validate() throws(InvalidConfig)
}

extension KeyboardConfig: ConfigSection {
    static var file: ConfigFile { .keyboard }
    static var empty: KeyboardConfig { KeyboardConfig() }
    func validate() throws(InvalidConfig) { _ = try KeyboardPlan(self) }
}

extension MouseConfig: ConfigSection {
    static var file: ConfigFile { .mouse }
    static var empty: MouseConfig { MouseConfig() }
    func validate() throws(InvalidConfig) { _ = try MousePlan(self) }
}

extension WMConfig: ConfigSection {
    static var file: ConfigFile { .wm }
    static var empty: WMConfig { WMConfig() }
    func validate() throws(InvalidConfig) {}
}

public enum ConfigLoader {
    /// `$XDG_CONFIG_HOME/hyperspace`, falling back to `~/.config/hyperspace`.
    public static var defaultDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "hyperspace")
    }

    public static func url(_ file: ConfigFile, in directory: URL = defaultDirectory) -> URL {
        directory.appending(path: file.fileName)
    }

    /// Loads every file. A file with errors keeps its section from `previous` (the last good
    /// config), so a mistake in mouse.toml doesn't turn off the keyboard.
    public static func load(from directory: URL = defaultDirectory, previous: Config = Config()) -> (config: Config, errors: [ConfigError]) {
        var config = previous
        var errors: [ConfigError] = []
        func apply<T: ConfigSection>(_ result: Result<T, ConfigError>, _ set: (T) -> Void) {
            switch result {
            case let .success(section): set(section)
            case let .failure(error): errors.append(error)
            }
        }
        apply(load(KeyboardConfig.self, in: directory)) { config.keyboard = $0 }
        apply(load(MouseConfig.self, in: directory)) { config.mouse = $0 }
        apply(load(WMConfig.self, in: directory)) { config.wm = $0 }
        return (config, errors)
    }

    static func load<T: ConfigSection>(_: T.Type, in directory: URL) -> Result<T, ConfigError> {
        let url = url(T.file, in: directory)
        do {
            return parse(T.self, try String(contentsOf: url, encoding: .utf8), path: url.path)
        } catch CocoaError.fileReadNoSuchFile {
            return .success(T.empty)
        } catch {
            return .failure(ConfigError(path: url.path, message: error.localizedDescription))
        }
    }

    static func parse<T: ConfigSection>(_: T.Type, _ text: String, path: String? = nil) -> Result<T, ConfigError> {
        let path = path ?? T.file.fileName
        do {
            let section = try TOMLDecoder().decode(T.self, from: text)
            try section.validate()
            return .success(section)
        } catch let error as InvalidConfig {
            return .failure(ConfigError(path: path, message: error.message))
        } catch let error as DecodingError {
            return .failure(ConfigError(path: path, message: describe(error)))
        } catch {
            return .failure(ConfigError(path: path, message: "\(error)"))
        }
    }

    /// Writes a commented starter file for each missing one. Returns all file URLs.
    @discardableResult
    public static func createTemplatesIfMissing(in directory: URL = defaultDirectory) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ConfigFile.allCases.map { file in
            let url = url(file, in: directory)
            if !FileManager.default.fileExists(atPath: url.path) {
                try template(file).write(to: url, atomically: true, encoding: .utf8)
            }
            return url
        }
    }

    /// Turns a DecodingError into "capslock.alone: <reason>".
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

    public static func template(_ file: ConfigFile) -> String {
        switch file {
        case .keyboard: keyboardTemplate
        case .mouse: mouseTemplate
        case .wm: wmTemplate
        }
    }

    private static let header = """
    # Saved changes are applied immediately. Remapped keys and buttons only do what is
    # mapped here; everything else is untouched. Per-app rules use the app's bundle id:
    #   hsctl apps                            bundle ids of the running apps
    #   osascript -e 'id of app "Safari"'     bundle id of any installed app
    """

    static let keyboardTemplate = """
    # HyperSpace — keyboard
    \(header)
    #
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

    # Simple remaps, always active (must come before any [section]). key -> key works
    # everywhere, even in password fields; key -> combo needs HyperSpace running.
    # "device" limits a remap to one keyboard.
    # simple = [
    #   { from = "command.right", to = "option.right" },
    #   { from = "f1", to = "cmd-space" },
    # ]

    # Caps Lock. Once this section exists, Caps Lock no longer toggles caps lock
    # (if it was on, HyperSpace turns it off).
    # [capslock]
    # hold = "shift-ctrl-opt"     # while held, Caps Lock acts as these modifiers
    # led = "held"                # LED: "held" = on while Caps Lock is held, "off" = always off (default)
    # alone = "escape"            # action when tapped alone (default: nothing)
    # tap_timeout_ms = 200        # held longer than this = not a tap, "alone" doesn't fire

    # Caps + key overrides, in EVERY app: listed keys do this instead of getting the
    # modifiers above. Good for global shortcuts like opening apps.
    # [capslock.map]
    # return = { shell = "open -a 'Visual Studio Code'" }
    # h = "arrow.left"

    # Caps + key overrides only while that app is in front.
    # [[capslock.app]]
    # bundle_id = "com.microsoft.VSCode"
    # map = { d = "cmd-shift-k" }

    """

    static let mouseTemplate = """
    # HyperSpace — mouse
    \(header)
    #
    # Buttons: button1 = right, button2 (or middle) = wheel click,
    #          button3 (or back) / button4 (or forward) = side buttons, button5...31 = extra.
    #          The left button can't be remapped.
    # Actions: "navigate.back" / "navigate.forward"  back/forward in every app
    #          "cmd-w"                                a key or combo (US key positions)
    #          { shell = "open -a Safari" }           run a shell command
    #          "none"                                 disable the button
    #          "passthrough"                          keep the normal behavior (for app exceptions)

    # [buttons]
    # button3 = "navigate.back"     # side button: back
    # button4 = "navigate.forward"  # side button: forward
    # middle = "cmd-w"              # wheel click: close tab

    # Per-app exceptions: these buttons behave differently in one app.
    # [[app]]
    # bundle_id = "com.google.Chrome"
    # buttons = { button3 = "passthrough", button4 = "passthrough" }

    # Wheel scrolling only; trackpads and Magic Mouse are never touched.
    # [scroll]
    # reverse = true                # invert the wheel direction
    # linear = true                 # same distance per notch, no acceleration
    # lines = 3                     # lines per notch when linear (1-20)

    """

    static let wmTemplate = """
    # HyperSpace — window manager (coming soon)
    \(header)

    # enabled = true

    """
}
