@testable import HyperSpaceCore
import Testing

struct MouseTests {
    private func plan(_ toml: String) throws -> InputPlan {
        try InputPlan(mouse: MousePlan(ConfigLoader.parse(MouseConfig.self, toml).get()))
    }

    private func error(_ toml: String) -> String? {
        if case let .failure(e) = ConfigLoader.parse(MouseConfig.self, toml) { return e.message }
        return nil
    }

    private let config = """
    [buttons]
    button3 = "navigate.back"
    forward = "navigate.forward"
    middle = "none"
    button5 = { shell = "say hi" }
    button6 = "volume.up"
    button7 = "media.next"
    button8 = "scroll.down"
    button9 = { scroll = "right", pixels = 40 }
    button10 = "click.double"

    [[app]]
    bundle_id = "com.google.Chrome"
    buttons = { back = "passthrough", forward = "passthrough" }
    """

    @Test func buttonsCompile() throws {
        let p = try plan(config)
        let tables = p.tables(forApp: nil)
        #expect(tables.buttons[3] == .system(.navigateBack))
        #expect(tables.buttons[4] == .system(.navigateForward))
        #expect(tables.buttons[2] == .drop)
        #expect(tables.buttons[5] == .shell("say hi"))
        #expect(tables.buttons[6] == .system(.volumeUp))
        #expect(tables.buttons[7] == .system(.mediaNext))
        #expect(tables.buttons[8] == .scroll(ScrollStep(dx: 0, dy: -3, pixels: false)))
        #expect(tables.buttons[9] == .scroll(ScrollStep(dx: -40, dy: 0, pixels: true)))
        #expect(tables.buttons[10] == .system(.clickDouble))
        #expect(tables.buttons[1] == nil)
        #expect(p.needsEventTap)

        let chrome = p.tables(forApp: "com.google.Chrome")
        #expect(chrome.buttons[3] == nil)
        #expect(chrome.buttons[4] == nil)
        #expect(chrome.buttons[2] == .drop)
    }

    @Test func invalidInputsAreConfigErrors() {
        #expect(error("[buttons]\nbutton0 = \"escape\"")?.contains("left button") == true)
        #expect(error("[buttons]\nthumb = \"escape\"")?.contains("unknown mouse input 'thumb'") == true)
        #expect(error("[buttons]\nback = \"cmd-nope\"")?.contains("unknown key, combo or action") == true)
        #expect(error("[[device]]\nmatch = { vendor = 1 }")?.contains("unknown key") == true)
        #expect(error("[[device]]\nspeed = 0.5")?.contains("needs name, vendor or product") == true)
        #expect(error("[pointer]\nspeed = 2")?.contains("between 0 and 1") == true)
        #expect(error("[scroll]\nlines = 0")?.contains("between 1 and 20") == true)
        #expect(error("[buttons]\nmiddle = \"scroll.sideways\"")?.contains("unknown scroll direction") == true)
        #expect(error("[buttons]\nmiddle = { scroll = \"up\", lines = 2, pixels = 3 }")?.contains("either `lines` or `pixels`") == true)
        #expect(error("[buttons]\nmiddle = { shell = \"x\", lines = 2 }")?.contains("go with `scroll`") == true)
    }

    @Test func backButtonFiresOnceAndReleaseIsSwallowed() throws {
        let tables = try plan(config).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.button(3, down: true, tables: tables) == .emit(.system(.navigateBack)))
        #expect(e.swallowed(3) != nil)
        #expect(e.button(3, down: false, tables: tables) == .drop)
        #expect(e.swallowed(3) == nil)
    }

    @Test func unmappedButtonsPassThrough() throws {
        let tables = try plan(config).tables(forApp: "com.google.Chrome")
        var e = MouseEngine()
        #expect(e.button(3, down: true, tables: tables) == .pass)
        #expect(e.swallowed(3) == nil)
        #expect(e.button(3, down: false, tables: tables) == .pass)
        #expect(e.button(1, down: true, tables: tables) == .pass)
    }

    @Test func navigationRules() throws {
        let rules = try plan("[navigate]\nswipe = [\"com.example.\"]\nbuttons = [\"com.apple.Xcode\"]").mouse.navigation
        #expect(rules.usesSwipe("com.apple.Safari"))
        #expect(rules.usesSwipe("com.example.Editor"))
        #expect(!rules.usesSwipe("com.apple.Xcode"))
        #expect(!rules.usesSwipe("com.google.Chrome"))
    }

    @Test func droppedButtonDropsBothEdges() throws {
        let tables = try plan(config).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.button(2, down: true, tables: tables) == .drop)
        #expect(e.button(2, down: false, tables: tables) == .drop)
    }
}
