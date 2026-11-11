import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

@Suite struct TilingBindingsTests {
    private func pairs(_ bindings: [[String: Any]]) -> [String] {
        bindings.map { "\($0["keys"] as? String ?? "")=\($0["action"] as? String ?? "")" }
    }

    /// The last binding of an action is edited in place; the others stay as they are.
    @Test func editsTheLastBindingOfAnAction() {
        let bindings: [[String: Any]] = [
            ["keys": "hyper+h", "action": "focus left"],
            ["keys": "hyper+t", "action": "launch Terminal"],
            ["keys": "hyper+y", "action": "focus left"],
        ]
        let merged = TilingModel.mergedBindings(bindings, desired: [("focus left", "hyper+j")], scratchpadActions: [])
        #expect(pairs(merged) == ["hyper+h=focus left", "hyper+t=launch Terminal", "hyper+j=focus left"])
    }

    /// Empty keys remove the action's last binding; a new action is added at the end.
    @Test func clearsAndAdds() {
        let bindings: [[String: Any]] = [["keys": "hyper+f", "action": "float"], ["keys": "hyper+r", "action": "retile"]]
        let merged = TilingModel.mergedBindings(bindings, desired: [("float", ""), ("accordion", "hyper+a"), ("swap up", "")],
                                                scratchpadActions: [])
        #expect(pairs(merged) == ["hyper+r=retile", "hyper+a=accordion"])
    }

    /// An app taken off the scratchpad list loses every binding it had.
    @Test func dropsRemovedScratchpadApps() {
        let bindings: [[String: Any]] = [
            ["keys": "hyper+1", "action": "scratchpad com.apple.Notes"],
            ["keys": "hyper+2", "action": "move-to-scratchpad com.apple.Notes"],
            ["keys": "hyper+3", "action": "scratchpad com.apple.Terminal"],
        ]
        let merged = TilingModel.mergedBindings(bindings, desired: [],
                                                scratchpadActions: ["scratchpad com.apple.Terminal"])
        #expect(pairs(merged) == ["hyper+3=scratchpad com.apple.Terminal"])
    }

    /// Scratchpad apps in order of first appearance, the last binding of each action winning.
    @Test func readsScratchpadApps() {
        let bindings: [[String: Any]] = [
            ["keys": "hyper+n", "action": "move-to-scratchpad com.apple.Notes"],
            ["keys": "hyper+t", "action": "scratchpad com.apple.Terminal"],
            ["keys": "hyper+m", "action": "scratchpad com.apple.Notes"],
            ["keys": "hyper+o", "action": "scratchpad com.apple.Notes"],
            ["keys": "hyper+x", "action": "focus left"],
        ]
        let pads = TilingModel.scratchpadApps(from: bindings)
        #expect(pads.map(\.bundleID) == ["com.apple.Notes", "com.apple.Terminal"])
        #expect(pads[0].toggleKeys == "hyper+o" && pads[0].tileKeys == "hyper+n")
        #expect(pads[1].toggleKeys == "hyper+t" && pads[1].tileKeys == "")
    }
}

/// App rules follow their workspace by identity; names are only saved when valid.
@Suite struct WorkspaceIdentityTests {
    private func workspace(_ name: String) -> TilingModel.Workspace {
        TilingModel.Workspace(name: name, savedName: name, switchKeys: "", moveKeys: "")
    }

    @Test func rulesResolveByNameOrNumber() {
        let spaces = [workspace("web"), workspace("code")]
        let rules = TilingModel.assignments(from: [
            ["app": "a", "workspace": "code"], ["app": "b", "workspace": "1"], ["app": "c", "workspace": "nope"],
        ], workspaces: spaces)
        #expect(rules.map(\.workspace) == [spaces[1].id, spaces[0].id, nil])
    }

    @Test func numbersAndUnknownNamesAreWrittenBackAsTheyWere() {
        let spaces = [workspace("web"), workspace("code")]
        let rules = TilingModel.assignments(from: [
            ["app": "b", "workspace": "1"], ["app": "c", "workspace": "nope"],
        ], workspaces: spaces)
        let written = TilingModel.assignEntries(rules, workspaces: spaces)
        #expect(written.map { $0["workspace"] as? String } == ["1", "nope"])
    }

    @Test func renamingKeepsTheRuleOnItsWorkspace() {
        var spaces = [workspace("web"), workspace("we")]
        let rules = TilingModel.assignments(from: [["app": "safari", "workspace": "web"]], workspaces: spaces)
        // "we" is renamed to "web2" through "web": the rule stays on the first workspace.
        spaces[1].savedName = "web2"
        spaces[0].savedName = "browser"
        let written = TilingModel.assignEntries(rules, workspaces: spaces)
        #expect(written.first?["workspace"] as? String == "browser")
    }

    @Test func rulesOfARemovedWorkspaceGo() {
        let spaces = [workspace("web"), workspace("code")]
        let rules = TilingModel.assignments(from: [["app": "a", "workspace": "code"]], workspaces: spaces)
        #expect(TilingModel.assignEntries(rules, workspaces: [spaces[0]]).isEmpty)
    }

    @Test func emptyAndTakenNamesAreNotSaved() {
        #expect(!TilingModel.isValidName("", others: ["web"]))
        #expect(!TilingModel.isValidName("  ", others: []))
        #expect(!TilingModel.isValidName("web", others: ["web"]))
        #expect(TilingModel.isValidName("web2", others: ["web"]))
    }

    @Test func configRejectsTwoWorkspacesWithTheSameName() {
        #expect(throws: ConfigError.self) {
            try config(#"{ "tiling": { "workspaces": [ { "name": "web" }, { "name": "web" } ] } }"#)
        }
    }
}

/// Settings compares shortcuts and actions by meaning, as the config does.
@Suite struct MeaningTests {
    @Test func shortcutsCompareByKeyAndModifiers() {
        #expect(TilingModel.comboKey("hyper+h") == TilingModel.comboKey("cmd+alt+ctrl+shift+h"))
        #expect(TilingModel.comboKey("esc") == TilingModel.comboKey("escape"))
        #expect(TilingModel.comboKey("hyper+h") != TilingModel.comboKey("hyper+j"))
    }

    @Test func actionsCompareByMeaning() {
        #expect(TilingModel.sameAction("Focus Left", "focus left"))
        #expect(TilingModel.sameAction("resize width 50", "resize width +50"))
        #expect(!TilingModel.sameAction("focus left", "swap left"))
        #expect(!TilingModel.sameAction("not an action", "focus left"))
    }

    @Test func aHandWrittenSpellingIsEditedInPlace() {
        let bindings: [[String: Any]] = [["keys": "hyper+h", "action": "Focus Left"]]
        let merged = TilingModel.mergedBindings(bindings, desired: [("focus left", "hyper+j")], scratchpadActions: [])
        #expect(merged.count == 1)
        #expect(merged.first?["keys"] as? String == "hyper+j")
    }
}
