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
    func validate() throws(InvalidConfig) {
        _ = try WMSettings(self)
    }
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
    # Try any action right away with `hsctl do <action>`, e.g. hsctl do volume.up
    """

    /// The actions both files accept, documented once.
    private static let actions = """
    # Actions, for keys and mouse buttons alike:
    #   "cmd-w", "arrow.left"                  a key or combo (US key positions)
    #   "navigate.back" / "navigate.forward"   back/forward in every app, any layout
    #   "volume.up" / ".down" / ".mute"        volume
    #   "brightness.up" / ".down"              display brightness
    #   "keyboard.brightness.up" / ".down"     keyboard backlight
    #   "media.play" / ".next" / ".previous" / ".forward" / ".rewind"   playback (Spotify, Music...)
    #   "mission.control" / ".windows" / ".desktop" / ".launchpad"     Mission Control, app windows, desktop
    #   "space.left" / "space.right"           move one space (desktop)
    #   "window.maximize" / "window.minimize"  the focused window
    #   "lookup" / "zoom.smart"                Look Up & data detectors, smart zoom
    #   "click.left" / ".double" / ".right" / ".middle" / ".back" / ".forward"
    #   "scroll.up" / ".down" / ".left" / ".right"   3 lines
    #   { scroll = "down", lines = 5 }         or pixels = 40
    #   { app = "Safari" }                     open or focus an app (name or bundle id)
    #   { text = "me@example.com" }            type text
    #   { sequence = ["cmd-c", "cmd-tab", "cmd-v"] }   several actions in a row
    #   { shell = "open ~/Downloads" }         run a shell command
    #   { action = "volume.up", repeat = true }      repeat while held (key repeat rate)
    #   { action = "click.left", hold = true }       hold down while held: drag with it
    #   "none"                                 do nothing
    #   "passthrough"                          keep the normal behavior (for app exceptions)
    """

    static let keyboardTemplate = """
    # HyperSpace — keyboard
    \(header)
    #
    # Keys:      a...z, 0...9, f1...f20, escape, tab, space, return, backspace, delete.forward,
    #            arrow.left/.right/.up/.down, home, end, page.up, page.down, capslock,
    #            shift.left/.right, control.left/.right, option.left/.right, command.left/.right.
    #            Names are US key positions: symbol keys (bracket.open, minus...) may be
    #            different characters on other layouts. Quote names with dots in table
    #            headers: [layer."page.up"].
    # Modifiers: shift, ctrl, opt, cmd, fn, joined with "-" (e.g. "cmd-shift-k").
    \(actions)

    # Maximum time between the two taps of [double] (100-1000 ms; must come before any [section]).
    # double_tap_ms = 300

    # Remaps, always active. key -> key works everywhere, even in password fields;
    # anything else (combos, actions...) needs HyperSpace running.
    # [map]
    # "command.right" = "option.right"
    # f1 = "cmd-space"
    # f10 = "volume.mute"
    # f11 = { action = "volume.down", repeat = true }
    # f12 = { action = "volume.up", repeat = true }

    # [map] overrides while one app is in front.
    # [[app]]
    # bundle_id = "com.apple.Terminal"
    # map = { f1 = "passthrough" }

    # key -> key for one keyboard only. Match by name (part of it), vendor and/or product
    # (ids: `hidutil list`).
    # [[device]]
    # name = "magic keyboard"
    # map = { "option.left" = "command.left" }

    # Double tap a key: the first tap works as usual, the second does the action.
    # Modifier keys work too, when tapped alone.
    # [double]
    # "shift.left" = "cmd-space"
    # escape = "mission.control"

    # Caps Lock. Once this section exists, Caps Lock no longer toggles caps lock
    # (if it was on, HyperSpace turns it off).
    # [capslock]
    # hold = "shift-ctrl-opt"     # while held, other keys get these modifiers ("shift-ctrl-opt-cmd" for all four)
    # led = "held"                # LED: "held" = on while Caps Lock is held, "off" = always off (default)
    # alone = "escape"            # action when tapped alone (default: nothing)
    # tap_timeout_ms = 200        # held longer than this = not a tap, "alone" doesn't fire

    # Caps + key, in EVERY app: listed keys do this instead of getting the modifiers above.
    # [capslock.map]
    # return = { app = "Visual Studio Code" }
    # h = "arrow.left"
    # u = "volume.up"

    # Caps + key only while that app is in front.
    # [[capslock.app]]
    # bundle_id = "com.microsoft.VSCode"
    # map = { d = "cmd-shift-k" }

    # Layers and dual-role keys: any other key works like [capslock] (same options, no led).
    # Tapped, it types `alone`; held, the other keys use its map and `hold` modifiers.
    # While typing fast, a key pressed during the layer key counts as held only if it's
    # released first, so normal typing isn't affected.
    # [layer.space]
    # alone = "space"
    # map = { j = "arrow.down", k = "arrow.up", h = "arrow.left", l = "arrow.right" }
    #
    # [layer.return]              # Return when tapped, Control when held
    # alone = "return"
    # hold = "ctrl"

    """

    static let mouseTemplate = """
    # HyperSpace — mouse
    \(header)
    #
    # Buttons: button1 = right, button2 (or middle) = wheel click,
    #          button3 (or back) / button4 (or forward) = side buttons, button5...31 = extra.
    #          Logitech: dpi (the Lift's top button), gesture, or any control as "cid.0x00c3":
    #          read over Logitech's protocol, these never reach macOS on their own.
    #          The left button can't be remapped.
    \(actions)

    # [buttons]
    # back = "navigate.back"
    # forward = "navigate.forward"
    # middle = "media.play"
    # dpi = "mission.control"

    # Per-app exceptions: these buttons behave differently in one app.
    # [[app]]
    # bundle_id = "com.google.Chrome"
    # buttons = { back = "passthrough", forward = "passthrough" }

    # While a button is held, the wheel and mouse movement do something else. Tapped alone,
    # the button still does its own action (or its normal click).
    # [hold.back]
    # "scroll.up" = "volume.up"           # per wheel notch
    # "scroll.down" = "volume.down"
    # "move.left" = "space.left"          # mouse gesture: move while holding
    # "move.right" = "space.right"
    # distance = 60                       # points of movement per gesture

    # Wheel scrolling only; trackpads and Magic Mouse are never touched.
    # [scroll]
    # smooth = true               # the notched wheel glides like a trackpad
    # reverse = true              # invert the wheel: true, "vertical" or "horizontal"
    # linear = true               # same distance per notch, no acceleration
    # lines = 3                   # lines per notch when linear or smooth (1-20)
    # fast = "opt"                # hold these modifiers to scroll faster...
    # fast_factor = 3             # ...by this much

    # Pointer speed and acceleration for every mouse (trackpads keep the macOS settings).
    # [pointer]
    # speed = 0.5                 # 0 (slow) ... 1 (fast)
    # acceleration = false        # false = linear (moves exactly with your hand), or 0-20

    # Pointer settings for some devices only; they win over [pointer].
    # [[device]]
    # name = "lift"               # part of the product name; or vendor = 0x046d, product = ...
    # speed = 0.6
    # acceleration = false

    # How navigate.back/.forward reach an app (bundle id prefixes). Apple apps, Firefox,
    # Opera and ForkLift get a trackpad swipe; every other app gets mouse buttons 4/5.
    # [navigate]
    # swipe = ["com.example.App"]   # these get a swipe too
    # buttons = ["com.apple.Xcode"] # these get buttons 4/5 instead

    """

    static let wmTemplate = #"""
    # HyperSpace — window manager
    \#(header)
    #
    # AeroSpace's keys and commands for windows. While this file sets nothing (only comments),
    # the window manager is off. Commands also work from the terminal: hsctl workspace 2

    # accordion-padding = 30
    # default-root-container-layout = 'tiles'        # tiles | accordion
    # default-root-container-orientation = 'auto'    # horizontal | vertical | auto
    # on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
    # automatically-unhide-macos-hidden-apps = false
    # focus-follows-mouse.enabled = false

    # Workspaces kept alive when empty; omitted = the ones named in bindings.
    # persistent-workspaces = ['1', '2', '3']

    # Gaps: a number, or per monitor: [{ monitor.main = 16 }, { monitor."dell" = 32 }, 24]
    # gaps.inner.horizontal = 0
    # gaps.inner.vertical =   0
    # gaps.outer.left =       0
    # gaps.outer.bottom =     0
    # gaps.outer.top =        0
    # gaps.outer.right =      0

    # Workspace -> monitor: main, secondary, a number from the left, or a regex on the name.
    # [workspace-to-monitor-force-assignment]
    #     1 = 'main'
    #     2 = 'secondary'

    # Keys: a-z, 0-9, keypad0-9, f1-f20, minus, equal, period, comma, slash, backslash, quote,
    # semicolon, backtick, leftSquareBracket, rightSquareBracket, space, enter, esc, backspace,
    # tab, pageUp, pageDown, home, end, forwardDelete, left, down, up, right.
    # Modifiers: cmd, alt, ctrl, shift. Commands: hsctl --help
    # [mode.main.binding]
    #     alt-slash = 'layout tiles horizontal vertical'
    #     alt-comma = 'layout accordion horizontal vertical'
    #     alt-h = 'focus left'
    #     alt-j = 'focus down'
    #     alt-k = 'focus up'
    #     alt-l = 'focus right'
    #     alt-shift-h = 'move left'
    #     alt-shift-j = 'move down'
    #     alt-shift-k = 'move up'
    #     alt-shift-l = 'move right'
    #     alt-minus = 'resize smart -50'
    #     alt-equal = 'resize smart +50'
    #     alt-1 = 'workspace 1'
    #     alt-2 = 'workspace 2'
    #     alt-shift-1 = 'move-node-to-workspace 1'
    #     alt-shift-2 = 'move-node-to-workspace 2'
    #     alt-tab = 'workspace-back-and-forth'
    #     alt-shift-tab = 'move-workspace-to-monitor --wrap-around next'
    #     alt-shift-semicolon = 'mode service'

    # [mode.service.binding]
    #     esc = ['reload-config', 'mode main']
    #     r = ['flatten-workspace-tree', 'mode main']
    #     f = ['layout floating tiling', 'mode main']
    #     backspace = ['close-all-windows-but-current', 'mode main']
    #     alt-shift-h = ['join-with left', 'mode main']
    #     alt-shift-j = ['join-with down', 'mode main']
    #     alt-shift-k = ['join-with up', 'mode main']
    #     alt-shift-l = ['join-with right', 'mode main']

    # [[on-window-detected]]
    #     if.app-id = 'com.apple.Terminal'
    #     run = 'move-node-to-workspace 2'
    """#
}
