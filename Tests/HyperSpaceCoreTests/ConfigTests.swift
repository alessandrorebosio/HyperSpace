@testable import HyperSpaceCore
import Testing

struct ConfigTests {
    private func error<T: ConfigSection>(_ type: T.Type, _ toml: String) -> String? {
        if case let .failure(e) = ConfigLoader.parse(type, toml) { return e.message }
        return nil
    }

    @Test func emptyFilesTurnEverythingOff() throws {
        #expect(try ConfigLoader.parse(KeyboardConfig.self, "").get() == KeyboardConfig())
        #expect(try ConfigLoader.parse(MouseConfig.self, "").get() == MouseConfig())
        #expect(try ConfigLoader.parse(WMConfig.self, "").get() == WMConfig())
    }

    @Test func keyboardFileDecodes() throws {
        let keyboard = try ConfigLoader.parse(KeyboardConfig.self, """
        [map]
        "command.right" = "option.right"
        f5 = { shell = "open -a Safari" }

        [[app]]
        bundle_id = "com.apple.Terminal"
        map = { f5 = "passthrough" }

        [[device]]
        vendor = 0x05ac
        map = { "option.left" = "command.left" }

        [capslock]
        alone = "escape"
        hold = "shift-ctrl-opt"
        tap_timeout_ms = 150
        led = "held"

        [capslock.map]
        h = "arrow.left"
        t = { shell = "open -a Terminal" }
        "1" = { wm = "workspace 1" }
        q = "none"

        [[capslock.app]]
        bundle_id = "com.microsoft.VSCode"
        map = { d = "cmd-shift-k" }
        """).get()

        #expect(keyboard.map == ["command.right": .keys("option.right"), "f5": .shell("open -a Safari")])
        #expect(keyboard.app == [AppMap(bundleID: "com.apple.Terminal", map: ["f5": .passthrough])])
        #expect(keyboard.device == [DeviceMap(match: DeviceMatch(vendor: 0x05AC), map: ["option.left": "command.left"])])
        let caps = try #require(keyboard.capslock)
        #expect(caps.alone == .keys("escape"))
        #expect(caps.hold == "shift-ctrl-opt")
        #expect(caps.tapTimeoutMs == 150)
        #expect(caps.led == "held")
        #expect(caps.map["h"] == .keys("arrow.left"))
        #expect(caps.map["t"] == .shell("open -a Terminal"))
        #expect(caps.map["1"] == .wm("workspace 1"))
        #expect(caps.map["q"] == Action.none)
        #expect(caps.app == [AppMap(bundleID: "com.microsoft.VSCode", map: ["d": .keys("cmd-shift-k")])])
    }

    @Test func mouseFileDecodes() throws {
        let mouse = try ConfigLoader.parse(MouseConfig.self, """
        [buttons]
        button3 = "navigate.back"
        forward = "cmd-tab"

        [[app]]
        bundle_id = "com.google.Chrome"
        buttons = { button3 = "passthrough" }

        [scroll]
        reverse = "vertical"
        linear = true
        lines = 3

        [navigate]
        swipe = ["com.example."]
        buttons = ["com.apple.Xcode"]
        """).get()
        #expect(mouse.buttons["button3"] == .keys("navigate.back"))
        #expect(mouse.buttons["forward"] == .keys("cmd-tab"))
        #expect(mouse.app.first?.map["button3"] == .passthrough)
        #expect(mouse.navigate == NavigateConfig(swipe: ["com.example."], buttons: ["com.apple.Xcode"]))
        #expect(mouse.scroll == ScrollConfig(reverse: .vertical, linear: true, lines: 3))
    }

    @Test func wmFileDecodes() throws {
        let wm = try ConfigLoader.parse(WMConfig.self, """
        enabled = true
        gaps = { inner = 8, outer = 4 }

        [bindings]
        "alt-h" = "focus left"

        [[rule]]
        app = "com.apple.finder"
        layout = "floating"
        """).get()
        #expect(wm.enabled)
        #expect(wm.gaps == Gaps(inner: 8, outer: 4))
        #expect(wm.bindings["alt-h"] == ["focus left"])
        #expect(wm.rule == [WMRule(app: "com.apple.finder", layout: "floating", workspace: nil)])
    }

    @Test func capsLockDefaults() throws {
        let caps = try #require(try ConfigLoader.parse(KeyboardConfig.self, "[capslock]").get().capslock)
        #expect(caps.alone == Action.none)
        #expect(caps.tapTimeoutMs == 200)
        #expect(caps.led == nil)
        #expect(caps.map.isEmpty)
    }

    @Test func unknownKeyIsReportedWithItsPath() {
        #expect(error(KeyboardConfig.self, "[capslok]\nalone = \"escape\"")?.hasPrefix("capslok: unknown key") == true)
    }

    @Test func wrongTypeIsReportedWithItsPath() {
        // TOMLDecoder reports the line; our own messages add the key path.
        #expect(error(WMConfig.self, "enabled = \"yes\"") == "(Line 1) Invalid boolean value for key 'enabled'.")
        #expect(error(WMConfig.self, "gaps = 3") == "gaps: expected a table")
    }

    @Test func perAppTablesUseTheirFileNames() {
        #expect(error(MouseConfig.self, "[[app]]\nbundle_id = \"a\"\nmap = {}")?.contains("unknown key") == true)
        #expect(error(KeyboardConfig.self, "[[app]]\nbundle_id = \"a\"\nbuttons = {}")?.contains("unknown key") == true)
    }

    @Test func actionTableNeedsExactlyOneKind() {
        #expect(error(MouseConfig.self, "[buttons]\nbutton3 = { shell = \"a\", wm = \"b\" }")?.contains("exactly one of") == true)
        #expect(error(MouseConfig.self, "[buttons]\nbutton3 = { run = \"a\" }")?.contains("unknown key") == true)
    }

    @Test func syntaxErrorsAreReported() {
        #expect(error(KeyboardConfig.self, "[capslock\n") != nil)
    }

    @Test func templatesAreValidAndEmpty() throws {
        #expect(try ConfigLoader.parse(KeyboardConfig.self, ConfigLoader.template(.keyboard)).get() == KeyboardConfig())
        #expect(try ConfigLoader.parse(MouseConfig.self, ConfigLoader.template(.mouse)).get() == MouseConfig())
        #expect(try ConfigLoader.parse(WMConfig.self, ConfigLoader.template(.wm)).get() == WMConfig())
    }
}
