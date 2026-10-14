@testable import HelmCore
import Testing

struct ConfigTests {
    private func parse(_ toml: String) throws -> Config {
        try ConfigLoader.parse(toml).get()
    }

    private func error(_ toml: String) -> String? {
        if case let .failure(e) = ConfigLoader.parse(toml) { return e.message }
        return nil
    }

    @Test func emptyConfigTurnsEverythingOff() throws {
        let config = try parse("")
        #expect(config == Config())
        #expect(config.keyboard.capslock == nil)
        #expect(!config.wm.enabled)
    }

    @Test func fullExampleDecodes() throws {
        let config = try parse("""
        [keyboard]
        simple = [{ from = "right_command", to = "right_option", device = { vendor = 0x05ac } }]

        [keyboard.capslock]
        alone = "escape"
        tap_timeout_ms = 150

        [keyboard.capslock.map]
        h = "left_arrow"
        t = { shell = "open -a Terminal" }
        "1" = { wm = "workspace 1" }
        q = "none"

        [[keyboard.capslock.app]]
        bundle_id = "com.microsoft.VSCode"
        map = { d = "cmd-shift-k" }

        [mouse.buttons]
        button3 = "navigate_back"
        "hidpp:0x00fd" = "cmd-tab"

        [[mouse.app]]
        bundle_id = "com.google.Chrome"
        buttons = { button3 = "passthrough" }

        [[mouse.device]]
        match = { vendor = 0x046d }
        scroll = { reverse = true, linear = true, lines = 3 }

        [wm]
        enabled = true
        gaps = { inner = 8, outer = 4 }

        [wm.bindings]
        "alt-h" = "focus left"

        [[wm.rule]]
        app = "com.apple.finder"
        layout = "floating"
        """)

        #expect(config.keyboard.simple == [SimpleRemap(from: "right_command", to: "right_option", device: DeviceMatch(vendor: 0x05AC))])
        let caps = try #require(config.keyboard.capslock)
        #expect(caps.alone == .keys("escape"))
        #expect(caps.tapTimeoutMs == 150)
        #expect(caps.map["h"] == .keys("left_arrow"))
        #expect(caps.map["t"] == .shell("open -a Terminal"))
        #expect(caps.map["1"] == .wm("workspace 1"))
        #expect(caps.map["q"] == Action.none)
        #expect(caps.app == [AppKeyMap(bundleID: "com.microsoft.VSCode", map: ["d": .keys("cmd-shift-k")])])

        #expect(config.mouse.buttons["button3"] == .keys("navigate_back"))
        #expect(config.mouse.buttons["hidpp:0x00fd"] == .keys("cmd-tab"))
        #expect(config.mouse.app.first?.buttons["button3"] == .passthrough)
        #expect(config.mouse.device.first?.match.vendor == 0x046D)
        #expect(config.mouse.device.first?.scroll == ScrollConfig(reverse: true, linear: true, lines: 3))

        #expect(config.wm.enabled)
        #expect(config.wm.gaps == Gaps(inner: 8, outer: 4))
        #expect(config.wm.bindings["alt-h"] == "focus left")
        #expect(config.wm.rule == [WMRule(app: "com.apple.finder", layout: "floating", workspace: nil)])
    }

    @Test func capsLockDefaults() throws {
        let caps = try #require(try parse("[keyboard.capslock]").keyboard.capslock)
        #expect(caps.alone == Action.none)
        #expect(caps.tapTimeoutMs == 200)
        #expect(caps.map.isEmpty)
    }

    @Test func unknownKeyIsReportedWithItsPath() {
        let message = error("""
        [keyboard.capslok]
        alone = "escape"
        """)
        #expect(message?.hasPrefix("keyboard.capslok: unknown key") == true)
    }

    @Test func wrongTypeIsReportedWithItsPath() {
        // TOMLDecoder reports the line; our own messages add the key path.
        #expect(error("[wm]\nenabled = \"yes\"") == "(Line 2) Invalid boolean value for key 'enabled'.")
        #expect(error("[wm]\ngaps = 3") == "wm.gaps: expected a table")
    }

    @Test func actionTableNeedsExactlyOneKind() {
        #expect(error("[mouse.buttons]\nbutton3 = { shell = \"a\", wm = \"b\" }")?.contains("exactly one of") == true)
        #expect(error("[mouse.buttons]\nbutton3 = { run = \"a\" }")?.contains("unknown key") == true)
    }

    @Test func syntaxErrorsAreReported() {
        #expect(error("[keyboard\n") != nil)
    }

    @Test func templateIsValidConfig() throws {
        #expect(try parse(ConfigLoader.template) == Config())
    }
}
