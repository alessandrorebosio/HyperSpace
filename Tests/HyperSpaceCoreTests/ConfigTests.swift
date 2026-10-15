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

    @Test func wmFileDecodesAeroSpaceFormat() throws {
        let wm = try ConfigLoader.parse(WMConfig.self, """
        accordion-padding = 5
        default-root-container-layout = 'tiles'
        default-root-container-orientation = 'auto'
        on-focused-monitor-changed = ['move-mouse monitor-lazy-center']
        automatically-unhide-macos-hidden-apps = false
        persistent-workspaces = ['1', '2', 'Develop']
        on-mode-changed = []
        focus-follows-mouse.enabled = false
        gaps.inner.horizontal = 5
        gaps.inner.vertical =   5
        gaps.outer.left =       5
        gaps.outer.bottom =     5
        gaps.outer.top =        [{ monitor.main = 16 }, 24]
        gaps.outer.right =      5

        [workspace-to-monitor-force-assignment]
            1 = '^built-in retina display$'
            2 = ['secondary', 'dell']

        [mode.main.binding]
            ctrl-alt-shift-h = 'focus left'
            ctrl-alt-shift-1 = 'workspace 1'
            ctrl-alt-shift-period = 'mode service'

        [mode.service.binding]
            esc = ['reload-config', 'mode main']

        [[on-window-detected]]
            if.app-id = 'com.apple.Terminal'
            run = ['move-node-to-workspace Shell']

        [[on-window-detected]]
            if = 'test %{app-bundle-id} = com.spotify.client'
            check-further-callbacks = true
            run = 'move-node-to-workspace Music'
        """).get()
        #expect(!wm.isEmpty)
        #expect(wm.accordionPadding == 5)
        #expect(wm.persistentWorkspaces == ["1", "2", "Develop"])
        #expect(wm.gaps.outerTop.fallback == 24)
        #expect(wm.gaps.outerTop.perMonitor.first?.pattern == "main")
        #expect(wm.workspaceToMonitorForceAssignment["2"] == ["secondary", "dell"])
        #expect(wm.modes["service"]?["esc"] == ["reload-config", "mode main"])
        #expect(wm.onWindowDetected.count == 2)
        #expect(wm.onWindowDetected[1].checkFurtherCallbacks)

        let settings = try WMSettings(wm)
        #expect(settings.persistentWorkspaces == ["1", "2", "Develop"])
        #expect(settings.hotkeys["main"]?[Hotkeys.index(code: 4, modifiers: [.control, .option, .shift])] == .wm("focus left"))
        #expect(settings.hotkeys["service"]?[Hotkeys.index(code: 53, modifiers: [])] == .sequence([.wm("reload-config"), .wm("mode main")]))
    }

    @Test func emptyWMFileMeansOff() throws {
        #expect(try ConfigLoader.parse(WMConfig.self, "# only comments").get().isEmpty)
    }

    @Test func wmFileErrors() {
        #expect(error(WMConfig.self, "gaps = 3") == "gaps: expected a table")
        #expect(error(WMConfig.self, "[mode.main.binding]\nalt-h = 'focus sideways'")?.contains("focus") == true)
        #expect(error(WMConfig.self, "[mode.main.binding]\nalt-h = 'mode nowhere'")?.contains("no [mode.nowhere.binding]") == true)
        #expect(error(WMConfig.self, "[mode.main.binding]\nsuper-h = 'focus left'")?.contains("unknown modifier") == true)
        #expect(error(WMConfig.self, "start-at-login = true")?.contains("unknown key") == true)
        #expect(error(WMConfig.self, "[[on-window-detected]]\nrun = 'layout floating'")?.contains("omitting 'if'") == true)
        #expect(error(WMConfig.self, "default-root-container-layout = 'grid'")?.contains("tiles or accordion") == true)
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
        #expect(error(WMConfig.self, "accordion-padding = \"yes\"")?.contains("accordion-padding") == true)
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
