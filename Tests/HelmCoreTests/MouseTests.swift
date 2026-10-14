@testable import HelmCore
import Testing

struct MouseTests {
    private func plan(_ toml: String) throws -> InputPlan {
        try InputPlan(ConfigLoader.parse(toml).get())
    }

    private func error(_ toml: String) -> String? {
        if case let .failure(e) = ConfigLoader.parse(toml) { return e.message }
        return nil
    }

    private let config = """
    [mouse.buttons]
    button3 = "navigate.back"
    forward = "navigate.forward"
    middle = "none"
    button5 = { shell = "say hi" }

    [[mouse.app]]
    bundle_id = "com.google.Chrome"
    buttons = { back = "passthrough", forward = "passthrough" }
    """

    @Test func buttonsCompile() throws {
        let p = try plan(config)
        let tables = p.tables(forApp: nil)
        #expect(tables.buttons[3] == .navigate(.back))
        #expect(tables.buttons[4] == .navigate(.forward))
        #expect(tables.buttons[2] == .drop)
        #expect(tables.buttons[5] == .shell("say hi"))
        #expect(tables.buttons[1] == nil)
        #expect(p.needsEventTap)

        let chrome = p.tables(forApp: "com.google.Chrome")
        #expect(chrome.buttons[3] == nil)
        #expect(chrome.buttons[4] == nil)
        #expect(chrome.buttons[2] == .drop)
    }

    @Test func invalidInputsAreConfigErrors() {
        #expect(error("[mouse.buttons]\nbutton0 = \"escape\"")?.contains("left button") == true)
        #expect(error("[mouse.buttons]\nthumb = \"escape\"")?.contains("unknown mouse input 'thumb'") == true)
        #expect(error("[mouse.buttons]\n\"hidpp:0x00fd\" = \"escape\"")?.contains("aren't supported yet") == true)
        #expect(error("[mouse.buttons]\nback = \"cmd-nope\"")?.contains("unknown key or combo") == true)
        #expect(error("[[mouse.device]]\nmatch = { vendor = 1 }")?.contains("per-device") == true)
        #expect(error("[mouse.scroll]\nlines = 0")?.contains("between 1 and 20") == true)
    }

    @Test func backButtonFiresOnceAndReleaseIsSwallowed() throws {
        let tables = try plan(config).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.button(3, down: true, tables: tables) == .emit(.navigate(.back)))
        #expect(e.isSwallowed(3))
        #expect(e.button(3, down: false, tables: tables) == .drop)
        #expect(!e.isSwallowed(3))
    }

    @Test func unmappedButtonsPassThrough() throws {
        let tables = try plan(config).tables(forApp: "com.google.Chrome")
        var e = MouseEngine()
        #expect(e.button(3, down: true, tables: tables) == .pass)
        #expect(!e.isSwallowed(3))
        #expect(e.button(3, down: false, tables: tables) == .pass)
        #expect(e.button(1, down: true, tables: tables) == .pass)
    }

    @Test func droppedButtonDropsBothEdges() throws {
        let tables = try plan(config).tables(forApp: nil)
        var e = MouseEngine()
        #expect(e.button(2, down: true, tables: tables) == .drop)
        #expect(e.button(2, down: false, tables: tables) == .drop)
    }
}
