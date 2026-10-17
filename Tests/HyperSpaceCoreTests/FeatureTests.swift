@testable import HyperSpaceCore
import Testing

/// Layers, double taps, hold tables, extended actions and pointer settings.
struct FeatureTests {
    private func keyboard(_ toml: String) throws -> ActiveTables {
        try InputPlan(keyboard: KeyboardPlan(ConfigLoader.parse(KeyboardConfig.self, toml).get())).tables(forApp: nil)
    }

    private func mouse(_ toml: String) throws -> MousePlan {
        try MousePlan(ConfigLoader.parse(MouseConfig.self, toml).get())
    }

    private let space: UInt16 = 49, j: UInt16 = 38, k: UInt16 = 40, ret: UInt16 = 36, c: UInt16 = 8
    private let ms: UInt64 = 1_000_000

    // MARK: Layers

    @Test func releaseVersionsCompareByNumber() {
        #expect(HyperSpace.isNewer("v0.2.1", than: "0.2.0"))
        #expect(HyperSpace.isNewer("v0.10.0", than: "0.9.1"), "numbers, not text")
        #expect(HyperSpace.isNewer("1.0", than: "0.9.9"))
        #expect(!HyperSpace.isNewer("v0.2.0", than: "0.2.0"))
        #expect(!HyperSpace.isNewer("v0.2", than: "0.2.0"), "a missing part is 0")
        #expect(!HyperSpace.isNewer("v0.1.1", than: "0.2.0"))
    }

    @Test func spaceLayerHoldsWhenTheNextKeyIsReleasedFirst() throws {
        let t = try keyboard("[layer.space]\nalone = \"space\"\nmap = { j = \"arrow.down\" }")
        var e = KeyEngine()
        #expect(e.handle(code: space, down: true, isRepeat: false, now: 0, tables: t) == .drop)
        #expect(e.handle(code: j, down: true, isRepeat: false, now: 10 * ms, tables: t) == .drop, "undecided: j waits")
        #expect(e.handle(code: j, down: false, isRepeat: false, now: 20 * ms, tables: t) == .drop)
        #expect(e.takeEmitBefore() == .key(Combo(parsing: "arrow.down")!), "j released first: it was a hold")
        #expect(e.handle(code: space, down: false, isRepeat: false, now: 30 * ms, tables: t) == .drop, "used: no space")
    }

    @Test func fastTypingStillTypesBothKeys() throws {
        let t = try keyboard("[layer.space]\nalone = \"space\"\nmap = { j = \"arrow.down\" }")
        var e = KeyEngine()
        _ = e.handle(code: space, down: true, isRepeat: false, now: 0, tables: t)
        _ = e.handle(code: j, down: true, isRepeat: false, now: 10 * ms, tables: t)
        // Space released before j: it was a tap, then a j.
        #expect(e.handle(code: space, down: false, isRepeat: false, now: 20 * ms, tables: t)
            == .emit(.sequence([.key(Combo(parsing: "space")!), .key(Combo(parsing: "j")!)])))
        #expect(e.handle(code: j, down: false, isRepeat: false, now: 30 * ms, tables: t) == .pass)
    }

    @Test func dualRoleKeyAddsModifiers() throws {
        let t = try keyboard("[layer.return]\nalone = \"return\"\nhold = \"ctrl\"")
        var e = KeyEngine()
        _ = e.handle(code: ret, down: true, isRepeat: false, now: 0, tables: t)
        _ = e.handle(code: c, down: true, isRepeat: false, now: 10 * ms, tables: t)
        _ = e.handle(code: c, down: false, isRepeat: false, now: 20 * ms, tables: t)
        #expect(e.takeEmitBefore() == .key(Combo(parsing: "ctrl-c")!))
        _ = e.handle(code: ret, down: false, isRepeat: false, now: 30 * ms, tables: t)

        _ = e.handle(code: ret, down: true, isRepeat: false, now: 100 * ms, tables: t)
        #expect(e.handle(code: ret, down: false, isRepeat: false, now: 150 * ms, tables: t) == .emit(.key(Combo(parsing: "return")!)))
    }

    @Test func aHeldLayerKeyReportsItsModifiers() throws {
        let t = try keyboard("[layer.return]\nalone = \"return\"\nhold = \"shift-ctrl-opt\"")
        var e = KeyEngine()
        #expect(e.layerModifiers(t).isEmpty)
        _ = e.handle(code: ret, down: true, isRepeat: false, now: 0, tables: t)
        #expect(e.layerModifiers(t) == [.shift, .control, .option])
        _ = e.handle(code: ret, down: false, isRepeat: false, now: 10 * ms, tables: t)
        #expect(e.layerModifiers(t).isEmpty)
    }

    @Test func longHoldDecidesAtOnce() throws {
        let t = try keyboard("[layer.space]\nalone = \"space\"\ntap_timeout_ms = 200\nmap = { j = \"arrow.down\" }")
        var e = KeyEngine()
        _ = e.handle(code: space, down: true, isRepeat: false, now: 0, tables: t)
        #expect(e.handle(code: j, down: true, isRepeat: false, now: 300 * ms, tables: t) == .rewrite(Combo(parsing: "arrow.down")!))
        #expect(e.handle(code: j, down: true, isRepeat: true, now: 400 * ms, tables: t) == .rewrite(Combo(parsing: "arrow.down")!))
    }

    @Test func layerKeysAreValidated() {
        func error(_ toml: String) -> String? {
            if case let .failure(e) = ConfigLoader.parse(KeyboardConfig.self, toml) { return e.message }
            return nil
        }
        #expect(error("[layer.\"shift.left\"]")?.contains("non-modifier") == true)
        #expect(error("[layer.space]\nled = \"held\"")?.contains("only [capslock]") == true)
        #expect(error("[map]\nspace = \"tab\"\n[layer.space]")?.contains("layer key") == true)
    }

    // MARK: Double tap

    @Test func doubleTapOfAKey() throws {
        let t = try keyboard("double_tap_ms = 300\n[double]\nescape = \"mission.control\"")
        var e = KeyEngine()
        #expect(e.handle(code: 53, down: true, isRepeat: false, now: 0, tables: t) == .pass, "first tap works as usual")
        _ = e.handle(code: 53, down: false, isRepeat: false, now: 50 * ms, tables: t)
        #expect(e.handle(code: 53, down: true, isRepeat: false, now: 200 * ms, tables: t) == .emit(.system(.missionControl)))
        #expect(e.handle(code: 53, down: false, isRepeat: false, now: 250 * ms, tables: t) == .drop)
        #expect(e.handle(code: 53, down: true, isRepeat: false, now: 2000 * ms, tables: t) == .pass)
    }

    @Test func doubleTapOfAModifier() throws {
        let t = try keyboard("[double]\n\"shift.left\" = \"cmd-space\"")
        var e = KeyEngine()
        #expect(e.modifier(code: 56, down: true, now: 0, tables: t) == nil)
        #expect(e.modifier(code: 56, down: false, now: 50 * ms, tables: t) == nil)
        #expect(e.modifier(code: 56, down: true, now: 150 * ms, tables: t) == nil)
        #expect(e.modifier(code: 56, down: false, now: 200 * ms, tables: t) == .key(Combo(parsing: "cmd-space")!))

        // Shift used for a capital in between: not a tap.
        _ = e.modifier(code: 56, down: true, now: 1000 * ms, tables: t)
        _ = e.handle(code: j, down: true, isRepeat: false, now: 1010 * ms, tables: t)
        #expect(e.modifier(code: 56, down: false, now: 1050 * ms, tables: t) == nil)
        _ = e.modifier(code: 56, down: true, now: 1100 * ms, tables: t)
        #expect(e.modifier(code: 56, down: false, now: 1150 * ms, tables: t) == nil)
    }

    // MARK: Actions

    @Test func extendedActionsDecode() throws {
        let p = try mouse("""
        [buttons]
        button5 = { app = "Safari" }
        button6 = { text = "hi" }
        button7 = { sequence = ["cmd-c", "volume.up"] }
        button8 = { action = "volume.up", repeat = true }
        button9 = { action = "click.left", hold = true }
        """)
        #expect(p.buttons[5] == .app("Safari"))
        #expect(p.buttons[6] == .text("hi"))
        #expect(p.buttons[7] == .sequence([.key(Combo(parsing: "cmd-c")!), .system(.volumeUp)]))
        #expect(p.buttons[8] == .repeating(.system(.volumeUp)))
        #expect(p.buttons[9] == .held(.system(.clickLeft)))
    }

    @Test func badActionTablesAreErrors() {
        func error(_ toml: String) -> String? {
            if case let .failure(e) = ConfigLoader.parse(MouseConfig.self, toml) { return e.message }
            return nil
        }
        #expect(error("[buttons]\nback = { action = \"volume.up\", hold = true }")?.contains("`hold` works with keys") == true)
        #expect(error("[buttons]\nback = { action = \"a\", repeat = true, hold = true }")?.contains("either `repeat` or `hold`") == true)
        #expect(error("[buttons]\nback = { sequence = [\"passthrough\"] }")?.contains("no meaning in a sequence") == true)
    }

    @Test func repeatingAndHeldButtons() throws {
        let t = InputPlan(mouse: try mouse("""
        [buttons]
        back = { action = "volume.up", repeat = true }
        forward = { action = "click.left", hold = true }
        """)).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.button(3, down: true, tables: t) == .down(.repeating(.system(.volumeUp))))
        #expect(e.button(3, down: false, tables: t) == .up(.repeating(.system(.volumeUp))))
        #expect(e.button(4, down: true, tables: t) == .down(.held(.system(.clickLeft))))
        #expect(e.swallowed(4) == .held(.system(.clickLeft)), "its drags become left drags")
        #expect(e.button(4, down: false, tables: t) == .up(.held(.system(.clickLeft))))
    }

    // MARK: Hold tables

    @Test func wheelWhileHoldingAButton() throws {
        let t = InputPlan(mouse: try mouse("""
        [buttons]
        back = "navigate.back"
        [hold.back]
        "scroll.up" = "volume.up"
        "scroll.down" = "volume.down"
        """)).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.scroll(dx: 0, dy: 1, tables: t) == .pass, "no button held")
        #expect(e.button(3, down: true, tables: t) == .drop)
        #expect(e.scroll(dx: 0, dy: 1, tables: t) == .emit(.system(.volumeUp)))
        #expect(e.scroll(dx: 0, dy: -1, tables: t) == .emit(.system(.volumeDown)))
        #expect(e.scroll(dx: 1, dy: 0, tables: t) == .pass, "unmapped direction scrolls")
        #expect(e.button(3, down: false, tables: t) == .drop, "used: no back")

        _ = e.button(3, down: true, tables: t)
        #expect(e.button(3, down: false, tables: t) == .emit(.system(.navigateBack)), "tapped: its own action")
    }

    @Test func gestureWhileHoldingAButton() throws {
        let t = InputPlan(mouse: try mouse("""
        [hold.middle]
        distance = 50
        "move.left" = "space.left"
        "move.right" = "space.right"
        """)).tables(forApp: nil)
        var e = MouseEngine()
        _ = e.button(2, down: true, tables: t)
        #expect(e.move(dx: -30, dy: 2, tables: t) == nil)
        #expect(e.move(dx: -30, dy: 2, tables: t) == .system(.spaceLeft))
        #expect(e.move(dx: 60, dy: 0, tables: t) == .system(.spaceRight))
        #expect(e.button(2, down: false, tables: t) == .drop)
        _ = e.button(2, down: true, tables: t)
        #expect(e.button(2, down: false, tables: t) == .click(2), "tapped with no action: a normal middle click")
    }

    // MARK: Scroll and pointer

    @Test func scrollSettings() throws {
        let p = try mouse("[scroll]\nreverse = \"horizontal\"\nsmooth = true\nfast = \"opt\"\nfast_factor = 4")
        #expect(p.scroll == ScrollPlan(reverseVertical: false, reverseHorizontal: true, linear: false, smooth: true,
                                       lines: 3, fast: .option, fastFactor: 4))
        #expect(try mouse("[scroll]\nreverse = true").scroll?.reverseVertical == true)
    }

    @Test func pointerSettingsPerDevice() throws {
        let p = try mouse("""
        [pointer]
        speed = 0.4
        acceleration = false
        [[device]]
        name = "lift"
        speed = 0.7
        acceleration = 1.5
        """).pointer
        #expect(p.settings(name: "LIFT VERTICAL", vendor: 0x046D, product: 1, isMouse: true)
            == PointerConfig(speed: 0.7, acceleration: .curve(1.5)))
        #expect(p.settings(name: "Other Mouse", vendor: 1, product: 1, isMouse: true)
            == PointerConfig(speed: 0.4, acceleration: .off))
        #expect(p.settings(name: "Magic Trackpad", vendor: 0x05AC, product: 1, isMouse: false) == nil)
    }
}
