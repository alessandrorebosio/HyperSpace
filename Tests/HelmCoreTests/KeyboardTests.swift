@testable import HelmCore
import Testing

struct KeyboardPlanTests {
    private func plan(_ toml: String) throws -> KeyboardPlan {
        try KeyboardPlan(ConfigLoader.parse(toml).get().keyboard)
    }

    private func error(_ toml: String) -> String? {
        if case let .failure(e) = ConfigLoader.parse(toml) { return e.message }
        return nil
    }

    @Test func combosParse() {
        #expect(Combo(parsing: "cmd-shift-k") == Combo(key: KeyNames.key("k")!, modifiers: [.command, .shift]))
        #expect(Combo(parsing: "ctrl-minus") == Combo(key: KeyNames.key("hyphen")!, modifiers: .control))
        #expect(Combo(parsing: "navigate_back") == Combo(key: KeyNames.key("open_bracket")!, modifiers: .command))
        #expect(Combo(parsing: "left_arrow")?.modifiers == [])
        #expect(Combo(parsing: "hyper-k") == nil)
        #expect(Combo(parsing: "cmd-") == nil)
    }

    @Test func keyTableIsConsistent() {
        let codes = Set(KeyNames.table.values.map(\.code))
        let usages = Set(KeyNames.table.values.map(\.usage))
        #expect(codes.count == usages.count, "every key code maps to exactly one HID usage")
        #expect(KeyNames.key("caps_lock") == Key(code: 57, usage: 0x39))
        #expect(KeyNames.key("f18") == Key(code: 79, usage: 0x6D))
    }

    @Test func simpleKeyRemapsGoToHIDLevel() throws {
        let p = try plan("""
        [keyboard]
        simple = [
          { from = "right_command", to = "right_option", device = { vendor = 0x05ac } },
          { from = "f1", to = "cmd-space" },
        ]
        """)
        #expect(p.hid == [HIDMapping(from: 0xE7, to: 0xE6, device: DeviceMatch(vendor: 0x05AC))])
        #expect(p.simple[122] == .key(Combo(parsing: "cmd-space")!))
        #expect(p.layer == nil)
        #expect(p.needsEventTap)
    }

    @Test func capsLockBecomesLayerTrigger() throws {
        let p = try plan("""
        [keyboard.capslock]
        alone = "escape"
        [keyboard.capslock.map]
        h = "left_arrow"
        q = "none"
        x = "passthrough"
        [[keyboard.capslock.app]]
        bundle_id = "com.example.app"
        map = { h = "home", j = "passthrough" }
        """)
        #expect(p.hid == [HIDMapping(from: 0x39, to: 0x6D, device: nil)])
        let layer = try #require(p.layer)
        #expect(layer.alone == .key(Combo(parsing: "escape")!))
        #expect(layer.base[4] == .key(Combo(parsing: "left_arrow")!))
        #expect(layer.base[12] == .drop)
        #expect(layer.base[7] == nil)
        #expect(p.tables(forApp: "com.example.app").layer?.map[4] == .key(Combo(parsing: "home")!))
        #expect(p.tables(forApp: "com.other").layer?.map[4] == .key(Combo(parsing: "left_arrow")!))
    }

    @Test func invalidKeysAreConfigErrors() {
        #expect(error("[keyboard.capslock.map]\nhh = \"left_arrow\"") == "keyboard.capslock.map.hh: unknown key 'hh'")
        #expect(error("[keyboard.capslock.map]\nh = \"cmd-lefty\"") == "keyboard.capslock.map.h: unknown key or combo 'cmd-lefty'")
        #expect(error("[keyboard]\nsimple = [{ from = \"left_shift\", to = \"cmd-a\" }]")?.contains("modifier to a combo") == true)
        #expect(error("[keyboard]\nsimple = [{ from = \"caps_lock\", to = \"escape\" }]\n[keyboard.capslock]")?.contains("already configured") == true)
    }
}

struct KeyEngineTests {
    let h: UInt16 = 4, j: UInt16 = 38, q: UInt16 = 12, t: UInt16 = 17, f1: UInt16 = 122
    let trigger = Layer.trigger.code
    let ms: UInt64 = 1_000_000

    var tables: ActiveTables {
        try! KeyboardPlan(ConfigLoader.parse("""
        [keyboard]
        simple = [{ from = "f1", to = "cmd-space" }]
        [keyboard.capslock]
        alone = "escape"
        tap_timeout_ms = 200
        [keyboard.capslock.map]
        h = "left_arrow"
        q = "none"
        t = { shell = "open -a Terminal" }
        """).get().keyboard).tables(forApp: nil)
    }

    private func combo(_ s: String) -> KeyEngine.Decision { .rewrite(Combo(parsing: s)!) }

    @Test func unmappedKeysPassThrough() {
        var e = KeyEngine()
        #expect(e.handle(code: j, down: true, isRepeat: false, now: 0, tables: tables) == .pass)
        #expect(e.handle(code: j, down: false, isRepeat: false, now: 0, tables: tables) == .pass)
    }

    @Test func layerRemapsWhileHeldOnly() {
        var e = KeyEngine()
        #expect(e.handle(code: trigger, down: true, isRepeat: false, now: 0, tables: tables) == .drop)
        #expect(e.handle(code: h, down: true, isRepeat: false, now: 1, tables: tables) == combo("left_arrow"))
        #expect(e.handle(code: h, down: true, isRepeat: true, now: 2, tables: tables) == combo("left_arrow"))
        #expect(e.handle(code: h, down: false, isRepeat: false, now: 3, tables: tables) == combo("left_arrow"))
        #expect(e.handle(code: j, down: true, isRepeat: false, now: 4, tables: tables) == .pass, "unmapped key under the layer")
        #expect(e.handle(code: j, down: false, isRepeat: false, now: 5, tables: tables) == .pass)
        #expect(e.handle(code: trigger, down: false, isRepeat: false, now: 6, tables: tables) == .drop, "layer was used: no alone action")
        #expect(e.handle(code: h, down: true, isRepeat: false, now: 7, tables: tables) == .pass, "layer released")
    }

    @Test func triggerRepeatsAreSwallowed() {
        var e = KeyEngine()
        _ = e.handle(code: trigger, down: true, isRepeat: false, now: 0, tables: tables)
        #expect(e.handle(code: trigger, down: true, isRepeat: true, now: 500 * ms, tables: tables) == .drop)
        #expect(e.handle(code: h, down: true, isRepeat: false, now: 600 * ms, tables: tables) == combo("left_arrow"))
    }

    @Test func releaseMatchesPressEvenAfterLayerEnds() {
        var e = KeyEngine()
        _ = e.handle(code: trigger, down: true, isRepeat: false, now: 0, tables: tables)
        _ = e.handle(code: h, down: true, isRepeat: false, now: 1, tables: tables)
        _ = e.handle(code: trigger, down: false, isRepeat: false, now: 2, tables: tables)
        #expect(e.handle(code: h, down: false, isRepeat: false, now: 3, tables: tables) == combo("left_arrow"))
    }

    @Test func tapAloneEmitsWithinTimeout() {
        var e = KeyEngine()
        _ = e.handle(code: trigger, down: true, isRepeat: false, now: 0, tables: tables)
        #expect(e.handle(code: trigger, down: false, isRepeat: false, now: 150 * ms, tables: tables) == .emit(.key(Combo(parsing: "escape")!)))
        _ = e.handle(code: trigger, down: true, isRepeat: false, now: 1000 * ms, tables: tables)
        #expect(e.handle(code: trigger, down: false, isRepeat: false, now: 1300 * ms, tables: tables) == .drop, "held too long")
    }

    @Test func dropAndShellFireOnce() {
        var e = KeyEngine()
        _ = e.handle(code: trigger, down: true, isRepeat: false, now: 0, tables: tables)
        #expect(e.handle(code: q, down: true, isRepeat: false, now: 1, tables: tables) == .drop)
        #expect(e.handle(code: q, down: false, isRepeat: false, now: 2, tables: tables) == .drop)
        #expect(e.handle(code: t, down: true, isRepeat: false, now: 3, tables: tables) == .emit(.shell("open -a Terminal")))
        #expect(e.handle(code: t, down: true, isRepeat: true, now: 4, tables: tables) == .drop)
        #expect(e.handle(code: t, down: false, isRepeat: false, now: 5, tables: tables) == .drop)
    }

    @Test func simpleRemapsWorkWithoutLayer() {
        var e = KeyEngine()
        #expect(e.handle(code: f1, down: true, isRepeat: false, now: 0, tables: tables) == combo("cmd-space"))
        #expect(e.handle(code: f1, down: false, isRepeat: false, now: 1, tables: tables) == combo("cmd-space"))
    }
}
