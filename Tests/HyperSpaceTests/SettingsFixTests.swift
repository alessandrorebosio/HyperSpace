import Foundation
import Testing
@testable import HyperSpace

/// The menu bar's problems: the permission and the config error are tracked apart.
@Suite struct StatusProblemTests {
    @Test func bothProblemsShowTogether() {
        #expect(StatusMenu.problems(permissionMissing: true, configError: "bad") == [.permission, .config("bad")])
    }

    /// Fixing the config leaves the missing permission reported, and granting it leaves the config error.
    @Test func fixingOneKeepsTheOther() {
        #expect(StatusMenu.problems(permissionMissing: true, configError: nil) == [.permission])
        #expect(StatusMenu.problems(permissionMissing: false, configError: "bad") == [.config("bad")])
        #expect(StatusMenu.problems(permissionMissing: false, configError: nil).isEmpty)
    }

    @Test func accessibilityDescriptionMentionsLockAndProblem() {
        #expect(StatusMenu.accessibilityDescription(workspace: nil, locked: false, problem: false) == "HyperSpace")
        #expect(StatusMenu.accessibilityDescription(workspace: "web", locked: true, problem: true)
            == "Workspace web, keyboard locked, needs attention")
        #expect(StatusMenu.accessibilityDescription(workspace: nil, locked: false, problem: true) == "HyperSpace, needs attention")
    }

    /// Settings' status: the permission first, then a config error; a login item error is not part of it.
    @Test func settingsHealth() {
        #expect(GeneralModel.health(accessibilityGranted: false, configProblem: true).text == Permissions.missingShort)
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: true).text == "Needs attention")
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: false).text == "Running")
    }
}

/// Removing a workspace, and what the confirmation lists.
@Suite struct WorkspaceRemovalTests {
    private func workspace(_ name: String, switchKeys: String = "", display: String = "") -> TilingModel.Workspace {
        TilingModel.Workspace(name: name, switchKeys: switchKeys, moveKeys: "", display: display)
    }

    /// Its app rules go off the page too, not only out of the file; rules naming no workspace stay.
    @Test func itsRulesGoWithIt() {
        let spaces = [workspace("web"), workspace("code")]
        let rules = TilingModel.assignments(from: [
            ["app": "a", "workspace": "code"], ["app": "b", "workspace": "web"], ["app": "c", "workspace": "nope"],
        ], workspaces: spaces)
        let (left, kept) = TilingModel.removing(spaces[1].id, from: spaces, assignments: rules)
        #expect(left.map(\.name) == ["web"])
        #expect(kept.map(\.app) == ["b", "c"])
    }

    @Test func lossesListShortcutsRulesAndPin() {
        let space = workspace("web", switchKeys: "hyper+1", display: "main")
        let rules = TilingModel.assignments(from: [["app": "Safari", "workspace": "web"]], workspaces: [space])
        let losses = TilingModel.removalLosses(of: space, assignments: rules, appName: { $0 })
        #expect(losses.count == 3)
        #expect(losses[0].hasPrefix("Its shortcut "))
        #expect(losses[1] == "The app rule of Safari")
        #expect(losses[2] == "Its display pin")
    }

    /// An empty workspace goes without asking.
    @Test func nothingToLose() {
        #expect(TilingModel.removalLosses(of: workspace("web"), assignments: [], appName: { $0 }).isEmpty)
    }

    @Test func typedNameWarnings() {
        #expect(TilingModel.nameWarning(typed: "web", saved: "web", others: []) == nil)
        #expect(TilingModel.nameWarning(typed: "web2", saved: "web", others: ["code"]) == nil)
        #expect(TilingModel.nameWarning(typed: " ", saved: "web", others: [])?.hasPrefix("A workspace needs a name") == true)
        #expect(TilingModel.nameWarning(typed: "code", saved: "web", others: ["code"])?.hasPrefix("Another workspace") == true)
    }
}

/// Duplicate warnings and the rules the pages refuse to add twice.
@Suite struct SettingsDuplicateTests {
    /// Keys used by bindings no page shows count as duplicates too.
    @Test func otherBindingsCount() {
        let bindings: [[String: Any]] = [
            ["keys": "hyper+t", "action": "launch Terminal"],
            ["keys": "hyper+h", "action": "focus left"],
            ["keys": "hyper+y", "action": "focus left"],
            ["keys": "hyper+n", "action": "scratchpad com.apple.Notes"],
        ]
        // The last "focus left" and the scratchpad binding are on the pages; the others are not.
        #expect(TilingModel.otherBindingKeys(bindings) == ["hyper+t", "hyper+h"])
        let duplicates = TilingModel.duplicates(["hyper+y", "hyper+n"] + TilingModel.otherBindingKeys(bindings) + ["cmd+alt+ctrl+shift+t"])
        #expect(duplicates == [TilingModel.comboKey("hyper+t")])
    }

    /// Unparsed modifiers are not the same as none.
    @Test func mouseRulesWithInvalidModifiers() {
        let plain = MouseModel.Rule(button: 3, modifiers: [], action: "navigate back")
        let invalid = MouseModel.Rule(button: 3, modifiers: [], action: "navigate forward", invalidModifiers: "bogus")
        #expect(!MouseModel.isDuplicate(plain, in: [plain, invalid]))
        #expect(!MouseModel.isDuplicate(invalid, in: [plain, invalid]))
        let again = MouseModel.Rule(button: 3, modifiers: [], action: "key cmd+c")
        #expect(MouseModel.isDuplicate(plain, in: [plain, invalid, again]))
    }

    @Test func floatingRuleThatExists() {
        let rule = TilingConfig.floatingRule(app: "com.apple.Notes", title: "Settings")!
        #expect(TilingModel.floatingRuleExists(app: "com.apple.Notes", title: "", floating: ["com.apple.Notes"], floatingWindows: []))
        #expect(!TilingModel.floatingRuleExists(app: nil, title: "", floating: ["com.apple.Notes"], floatingWindows: []))
        #expect(TilingModel.floatingRuleExists(app: "com.apple.Notes", title: " Settings ", floating: [], floatingWindows: [rule]))
        #expect(!TilingModel.floatingRuleExists(app: nil, title: "Settings", floating: [], floatingWindows: [rule]))
    }

    @Test func candidatesLeaveOutTakenApps() {
        let apps = [(name: "Notes", bundleID: "com.apple.Notes"), (name: "Safari", bundleID: "com.apple.Safari")]
        #expect(TilingModel.candidates(apps, excluding: ["com.apple.Notes"]).map(\.bundleID) == ["com.apple.Safari"])
    }
}

/// The helpers every settings model shares.
@Suite struct SettingsHelperTests {
    /// Rows keep their ids across a reload while they mean the same; each old id is used once.
    @Test func idsAreReused() {
        let a = UUID(), b = UUID(), c = UUID()
        let ids = reusedIDs(for: ["x", "y", "x", "z"], from: [("x", a), ("y", b), ("z", c)])
        #expect(ids[0] == a && ids[1] == b && ids[3] == c)
        #expect(![a, b, c].contains(ids[2]))
    }

    @Test func recordedShortcutInput() {
        #expect(ShortcutRecorder.input(key: "escape", modifiers: []) == .cancel)
        #expect(ShortcutRecorder.input(key: "delete", modifiers: []) == .clear)
        #expect(ShortcutRecorder.input(key: "escape", modifiers: .shift) == .keys(Modifiers.shift.text(key: "escape")))
        #expect(ShortcutRecorder.input(key: "k", modifiers: [.cmd, .shift]) == .keys(([.cmd, .shift] as Modifiers).text(key: "k")))
    }

    /// A reload that comes while the user edits is remembered, not lost; one that changes nothing is not.
    @Test func reloadWaitsForTheEdit() {
        var sync = FileSync<Void>(SyncedSlice(sections: "mouse"))
        sync.didLoad(["mouse": ["reverseScroll": true]])
        let same = sync.shouldReload(["mouse": ["reverseScroll": true]], editing: true)
        #expect(!same && !sync.reloadDeferred)
        let whileEditing = sync.shouldReload(["mouse": ["reverseScroll": false]], editing: true)
        #expect(!whileEditing && sync.reloadDeferred)
        let afterwards = sync.shouldReload(["mouse": ["reverseScroll": false]], editing: false)
        #expect(afterwards)
    }

    /// A syntax error reported earlier goes once the file parses again; other errors stay.
    @Test func syntaxErrorClearsWhenTheFileIsValid() {
        let status = SaveStatus()
        status.set(ConfigWriter.SyntaxError.message)
        status.fileIsValid()
        #expect(status.error == nil)
        status.set("disk full")
        status.fileIsValid()
        #expect(status.error == "disk full")
    }
}
