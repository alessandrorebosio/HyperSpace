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
    # hold = "shift-ctrl-opt"     # while held, other keys get these modifiers ("meh", "hyper")
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
    # The same format and options as AeroSpace (https://nikitabobko.github.io/AeroSpace/guide):
    # an ~/.aerospace.toml can be pasted here as is. While this file sets nothing (only
    # comments), the window manager is off. Below is AeroSpace's default config, commented out.
    # Commands also work from the terminal, like the `aerospace` CLI: hsctl workspace 2
    # Not supported: pipes ('|') and --stdin, the socket protocol and `subscribe`.

    # Config version for compatibility and deprecations
    # See: https://nikitabobko.github.io/AeroSpace/guide#config-version
    # Fallback value (if you omit the key): config-version = 1
    # config-version = 2

    # You can use it to add commands that run after AeroSpace startup.
    # Available commands : https://nikitabobko.github.io/AeroSpace/commands
    # after-startup-command = []

    # Start AeroSpace at login
    # start-at-login = false

    # Automatically reload the config when the config file is saved
    # After setting this to true, reload once manually to start the auto-reloading
    # auto-reload-config = false

    # Normalizations. See: https://nikitabobko.github.io/AeroSpace/guide#normalization
    # enable-normalization-flatten-containers = true
    # enable-normalization-opposite-orientation-for-nested-containers = true

    # See: https://nikitabobko.github.io/AeroSpace/guide#layouts
    # The 'accordion-padding' specifies the size of accordion padding
    # You can set 0 to disable the padding feature
    # accordion-padding = 30

    # Possible values: tiles|accordion
    # default-root-container-layout = 'tiles'

    # Possible values: horizontal|vertical|auto
    # 'auto' means: wide monitor (anything wider than high) gets horizontal orientation,
    #               tall monitor (anything higher than wide) gets vertical orientation
    # default-root-container-orientation = 'auto'

    # Mouse follows focus when focused monitor changes
    # Drop it from your config, if you don't like this behavior
    # See https://nikitabobko.github.io/AeroSpace/guide#on-focus-changed-callbacks
    # See https://nikitabobko.github.io/AeroSpace/commands#move-mouse
    # Fallback value (if you omit the key): on-focused-monitor-changed = []
    # on-focused-monitor-changed = ['move-mouse monitor-lazy-center']

    # You can effectively turn off macOS "Hide application" (cmd-h) feature by toggling this flag
    # Useful if you don't use this macOS feature, but accidentally hit cmd-h or cmd-alt-h key
    # Also see: https://nikitabobko.github.io/AeroSpace/goodies#disable-hide-app
    # automatically-unhide-macos-hidden-apps = false

    # List of workspaces that should stay alive even when they contain no windows,
    # even when they are invisible.
    # This config option is only available since 'config-version = 2'
    # Fallback value (if you omit the key): persistent-workspaces = []
    # persistent-workspaces = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B",
    #                          "C", "D", "E", "F", "G", "I", "M", "N", "O", "P", "Q",
    #                          "R", "S", "T", "U", "V", "W", "X", "Y", "Z"]

    # A callback that runs every time binding mode changes
    # See: https://nikitabobko.github.io/AeroSpace/guide#binding-modes
    # See: https://nikitabobko.github.io/AeroSpace/commands#mode
    # on-mode-changed = []

    # focus-follows-mouse.enabled = false

    # Possible values: (qwerty|dvorak|colemak)
    # See https://nikitabobko.github.io/AeroSpace/guide#key-mapping
    # key-mapping.preset = 'qwerty'

    # Gaps between windows (inner-*) and between monitor edges (outer-*).
    # Possible values:
    # - Constant:     gaps.outer.top = 8
    # - Per monitor:  gaps.outer.top = [{ monitor.main = 16 }, { monitor."some-pattern" = 32 }, 24]
    #                 In this example, 24 is a default value when there is no match.
    #                 Monitor pattern is the same as for 'workspace-to-monitor-force-assignment'.
    #                 See:
    #                 https://nikitabobko.github.io/AeroSpace/guide#assign-workspaces-to-monitors
    # gaps.inner.horizontal = 0
    # gaps.inner.vertical =   0
    # gaps.outer.left =       0
    # gaps.outer.bottom =     0
    # gaps.outer.top =        0
    # gaps.outer.right =      0

    # 'main' binding mode declaration
    # See: https://nikitabobko.github.io/AeroSpace/guide#binding-modes
    # 'main' binding mode must be always presented
    # Fallback value (if you omit the key): mode.main.binding = {}
    # [mode.main.binding]

        # All possible keys:
        # - Letters.        a, b, c, ..., z
        # - Numbers.        0, 1, 2, ..., 9
        # - Keypad numbers. keypad0, keypad1, keypad2, ..., keypad9
        # - F-keys.         f1, f2, ..., f20
        # - Special keys.   minus, equal, period, comma, slash, backslash, quote, semicolon,
        #                   backtick, leftSquareBracket, rightSquareBracket, space, enter, esc,
        #                   backspace, tab, pageUp, pageDown, home, end, forwardDelete,
        #                   sectionSign (ISO keyboards only, european keyboards only)
        # - Keypad special. keypadClear, keypadDecimalMark, keypadDivide, keypadEnter, keypadEqual,
        #                   keypadMinus, keypadMultiply, keypadPlus
        # - Arrows.         left, down, up, right

        # All possible modifiers: cmd, alt, ctrl, shift

        # All possible commands: https://nikitabobko.github.io/AeroSpace/commands

        # See: https://nikitabobko.github.io/AeroSpace/commands#exec-and-forget
        # You can uncomment the following lines to open up terminal with alt + enter shortcut
        # (like in i3)
        # alt-enter = '''exec-and-forget osascript -e \
        # 'tell application "Terminal" to tell (do script) to activate' '''

        # See: https://nikitabobko.github.io/AeroSpace/commands#layout
    #     alt-slash = 'layout tiles horizontal vertical'
    #     alt-comma = 'layout accordion horizontal vertical'

        # See: https://nikitabobko.github.io/AeroSpace/commands#focus
    #     alt-h = 'focus left'
    #     alt-j = 'focus down'
    #     alt-k = 'focus up'
    #     alt-l = 'focus right'

        # See: https://nikitabobko.github.io/AeroSpace/commands#move
    #     alt-shift-h = 'move left'
    #     alt-shift-j = 'move down'
    #     alt-shift-k = 'move up'
    #     alt-shift-l = 'move right'

        # See: https://nikitabobko.github.io/AeroSpace/commands#resize
    #     alt-minus = 'resize smart -50'
    #     alt-equal = 'resize smart +50'

        # See: https://nikitabobko.github.io/AeroSpace/commands#workspace
    #     alt-1 = 'workspace 1'
    #     alt-2 = 'workspace 2'
    #     alt-3 = 'workspace 3'
    #     alt-4 = 'workspace 4'
    #     alt-5 = 'workspace 5'
    #     alt-6 = 'workspace 6'
    #     alt-7 = 'workspace 7'
    #     alt-8 = 'workspace 8'
    #     alt-9 = 'workspace 9'
    #     alt-a = 'workspace A' # In your config, you can drop workspace bindings that you don't need
    #     alt-b = 'workspace B'
    #     alt-c = 'workspace C'
    #     alt-d = 'workspace D'
    #     alt-e = 'workspace E'
    #     alt-f = 'workspace F'
    #     alt-g = 'workspace G'
    #     alt-i = 'workspace I'
    #     alt-m = 'workspace M'
    #     alt-n = 'workspace N'
    #     alt-o = 'workspace O'
    #     alt-p = 'workspace P'
    #     alt-q = 'workspace Q'
    #     alt-r = 'workspace R'
    #     alt-s = 'workspace S'
    #     alt-t = 'workspace T'
    #     alt-u = 'workspace U'
    #     alt-v = 'workspace V'
    #     alt-w = 'workspace W'
    #     alt-x = 'workspace X'
    #     alt-y = 'workspace Y'
    #     alt-z = 'workspace Z'

        # See: https://nikitabobko.github.io/AeroSpace/commands#move-node-to-workspace
    #     alt-shift-1 = 'move-node-to-workspace 1'
    #     alt-shift-2 = 'move-node-to-workspace 2'
    #     alt-shift-3 = 'move-node-to-workspace 3'
    #     alt-shift-4 = 'move-node-to-workspace 4'
    #     alt-shift-5 = 'move-node-to-workspace 5'
    #     alt-shift-6 = 'move-node-to-workspace 6'
    #     alt-shift-7 = 'move-node-to-workspace 7'
    #     alt-shift-8 = 'move-node-to-workspace 8'
    #     alt-shift-9 = 'move-node-to-workspace 9'
    #     alt-shift-a = 'move-node-to-workspace A'
    #     alt-shift-b = 'move-node-to-workspace B'
    #     alt-shift-c = 'move-node-to-workspace C'
    #     alt-shift-d = 'move-node-to-workspace D'
    #     alt-shift-e = 'move-node-to-workspace E'
    #     alt-shift-f = 'move-node-to-workspace F'
    #     alt-shift-g = 'move-node-to-workspace G'
    #     alt-shift-i = 'move-node-to-workspace I'
    #     alt-shift-m = 'move-node-to-workspace M'
    #     alt-shift-n = 'move-node-to-workspace N'
    #     alt-shift-o = 'move-node-to-workspace O'
    #     alt-shift-p = 'move-node-to-workspace P'
    #     alt-shift-q = 'move-node-to-workspace Q'
    #     alt-shift-r = 'move-node-to-workspace R'
    #     alt-shift-s = 'move-node-to-workspace S'
    #     alt-shift-t = 'move-node-to-workspace T'
    #     alt-shift-u = 'move-node-to-workspace U'
    #     alt-shift-v = 'move-node-to-workspace V'
    #     alt-shift-w = 'move-node-to-workspace W'
    #     alt-shift-x = 'move-node-to-workspace X'
    #     alt-shift-y = 'move-node-to-workspace Y'
    #     alt-shift-z = 'move-node-to-workspace Z'

        # See: https://nikitabobko.github.io/AeroSpace/commands#workspace-back-and-forth
    #     alt-tab = 'workspace-back-and-forth'
        # See: https://nikitabobko.github.io/AeroSpace/commands#move-workspace-to-monitor
    #     alt-shift-tab = 'move-workspace-to-monitor --wrap-around next'

        # See: https://nikitabobko.github.io/AeroSpace/commands#mode
    #     alt-shift-semicolon = 'mode service'

    # 'service' binding mode declaration.
    # See: https://nikitabobko.github.io/AeroSpace/guide#binding-modes
    # [mode.service.binding]
    #     esc = ['reload-config', 'mode main']
    #     r = ['flatten-workspace-tree', 'mode main'] # reset layout
    #     f = ['layout floating tiling', 'mode main'] # Toggle between floating and tiling layout
    #     backspace = ['close-all-windows-but-current', 'mode main']

        # sticky is not yet supported https://github.com/nikitabobko/AeroSpace/issues/2
        #s = ['layout sticky tiling', 'mode main']

    #     alt-shift-h = ['join-with left', 'mode main']
    #     alt-shift-j = ['join-with down', 'mode main']
    #     alt-shift-k = ['join-with up', 'mode main']
    #     alt-shift-l = ['join-with right', 'mode main']
    """#
}
