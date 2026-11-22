import CoreGraphics
import Foundation
import Testing
@testable import HyperSpace

// The pure functions behind the Settings pages: static, so no page model (which saves to the
// real config) is ever created.

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
        TilingModel.Workspace(name: name, switchKeys: "", moveKeys: "")
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
        spaces[1].name = "web2"
        spaces[0].name = "browser"
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

@Suite struct DisplayOptionTests {
    private let screens = [makeScreen(1, name: "Built-in Retina Display"), makeScreen(2, x: 1000, name: "LG UltraFine")]

    @Test func positionsThenMonitors() {
        let options = TilingModel.displayOptions(pin: "", screens: screens)
        #expect(options.map(\.value) == ["", "main", "2", "3", "Built-in Retina Display", "LG UltraFine"])
        #expect(options.map(\.label) == ["Any display", "Main display", "Second display", "Third display",
                                         "Built-in Retina Display", "LG UltraFine"])
        #expect(options.filter(\.startsGroup).map(\.value) == ["Built-in Retina Display"])
    }

    @Test func onePositionPerDisplayBeyondThree() {
        let four = (1...4).map { makeScreen(CGDirectDisplayID($0), x: CGFloat($0) * 1000, name: "D\($0)") }
        #expect(TilingModel.displayOptions(pin: "", screens: four).map(\.value).prefix(5) == ["", "main", "2", "3", "4"])
    }

    @Test func pinsNotListedStillShow() {
        #expect(TilingModel.displayOptions(pin: "5", screens: screens).last?.label == "Display 5")
        #expect(TilingModel.displayOptions(pin: "1", screens: screens).last?.label == "Main display")
        #expect(TilingModel.displayOptions(pin: "Dell", screens: screens).last?.label == "Dell (not connected)")
        // A pin already offered is not repeated.
        #expect(TilingModel.displayOptions(pin: "2", screens: screens).filter { $0.value == "2" }.count == 1)
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
}

/// Only what changed since the load is written.
@Suite struct WriteIfChangedTests {
    @Test func anOptionIsWrittenOnceItDiffers() {
        var section: [String: Any] = ["gap": 7.5]
        section.write("gap", 7, since: 7)
        #expect(section["gap"] as? Double == 7.5)
        section.write("gap", 8, since: 7)
        #expect(section["gap"] as? Int == 8)
        // Never loaded: written.
        section.write("enabled", true, since: nil)
        #expect(section["enabled"] as? Bool == true)
    }

    @Test func aListIsWrittenOnceItDiffers() {
        let entries: [[String: Any]] = [["name": "1"], ["name": "web", "switch": "hyper+2"]]
        // The file's own form (a workspace with no name) stays while the list is as loaded.
        var section: [String: Any] = ["workspaces": [[String: Any](), ["name": "web", "switch": "hyper+2"]]]
        section.writeList("workspaces", entries, since: entries)
        #expect((section["workspaces"] as? [[String: Any]])?.first?.isEmpty == true)
        let renamed: [[String: Any]] = [["name": "mail"], ["name": "web", "switch": "hyper+2"]]
        section.writeList("workspaces", renamed, since: entries)
        #expect((section["workspaces"] as? [[String: Any]])?.first?["name"] as? String == "mail")
        // An empty list is left out of the file.
        section.writeList("workspaces", [], since: renamed)
        #expect(section["workspaces"] == nil)
    }

    /// A save with nothing to write does not add an empty section to the file.
    @Test func anUntouchedMissingSectionStaysOut() {
        var root: [String: Any] = ["tiling": ["gap": 8]]
        ConfigWriter.amend(&root, section: "mouse") { _ in }
        #expect(root["mouse"] == nil)
        ConfigWriter.amend(&root, section: "mouse") { $0["reverseScroll"] = true }
        #expect((root["mouse"] as? [String: Any])?["reverseScroll"] as? Bool == true)
        // A section the file has stays, even emptied.
        ConfigWriter.amend(&root, section: "tiling") { $0["gap"] = nil }
        #expect((root["tiling"] as? [String: Any])?.isEmpty == true)
    }

    @Test func workspacesAsTheFileHoldsThem() {
        let spaces = [
            TilingModel.Workspace(name: "web", switchKeys: "hyper+1", moveKeys: "", display: "main"),
            TilingModel.Workspace(name: "2", switchKeys: "", moveKeys: "hyper+shift+2"),
        ]
        let entries = TilingModel.workspaceEntries(spaces)
        #expect(entries[0] as NSDictionary == ["name": "web", "switch": "hyper+1", "display": "main"] as NSDictionary)
        #expect(entries[1] as NSDictionary == ["name": "2", "move": "hyper+shift+2"] as NSDictionary)
    }
}

/// What the recorders accept.
@Suite struct RecordingRulesTests {
    /// A key that types cannot be a global shortcut on its own, or with Shift alone.
    @Test func typingKeysNeedAModifier() {
        for key in ["a", "7", "space", "return", "tab", "comma", "keypad_5"] {
            #expect(ShortcutRecorder.typesText(key: key, modifiers: []), "\(key)")
            #expect(ShortcutRecorder.typesText(key: key, modifiers: .shift), "shift+\(key)")
            #expect(!ShortcutRecorder.typesText(key: key, modifiers: .cmd), "cmd+\(key)")
            #expect(!ShortcutRecorder.typesText(key: key, modifiers: [.alt, .shift]), "alt+shift+\(key)")
        }
    }

    @Test func functionAndNavigationKeysStayAllowed() {
        for key in ["f5", "f13", "left", "page_down", "home", "forward_delete", "keypad_clear", "escape"] {
            #expect(!ShortcutRecorder.typesText(key: key, modifiers: []), "\(key)")
        }
    }

    /// On the Keyboard page Esc is a key like any other, except as the target of a remap that has none yet.
    @Test func escapeCancelsOnlyANewRemapsTarget() {
        typealias Rule = KeyboardModel.Rule
        let new = Rule(from: "caps_lock", to: "", keyboard: KeyboardTarget.allText)
        let saved = Rule(from: "caps_lock", to: "hyper", keyboard: KeyboardTarget.allText)
        let empty = Rule(from: "", to: "", keyboard: KeyboardTarget.allText)
        #expect(KeyboardModel.escapeCancels(key: "escape", modifiers: [], field: .to(new.id), rule: new))
        // A remap that has a target is being edited: Esc is recorded, as it always was.
        #expect(!KeyboardModel.escapeCancels(key: "escape", modifiers: [], field: .to(saved.id), rule: saved))
        // As the key to remap, Esc is recorded too.
        #expect(!KeyboardModel.escapeCancels(key: "escape", modifiers: [], field: .from(empty.id), rule: empty))
        #expect(!KeyboardModel.escapeCancels(key: "escape", modifiers: .shift, field: .to(new.id), rule: new))
        #expect(!KeyboardModel.escapeCancels(key: "a", modifiers: [], field: .to(new.id), rule: new))
        #expect(!KeyboardModel.escapeCancels(key: "escape", modifiers: [], field: .to(new.id), rule: nil))
    }
}

/// Names, pins and lists the window pages clean up.
@Suite struct SettingsCleanupTests {
    /// "web " would look like "web": names are compared and saved without the spaces around them.
    @Test func workspaceNamesAreTrimmed() {
        #expect(TilingModel.trimmedName("  web ") == "web")
        #expect(!TilingModel.isValidName(" web ", others: ["web"]))
        #expect(TilingModel.isValidName(" mail ", others: ["web"]))
        // Spaces typed around the saved name are not a change, so nothing to warn about.
        #expect(TilingModel.nameWarning(typed: "web ", saved: "web", others: []) == nil)
        #expect(TilingModel.nameWarning(typed: " code", saved: "web", others: ["code"])?.hasPrefix("Another workspace") == true)
    }

    /// A pin is one of the display menu's choices however the file writes it.
    @Test func displayPinsAreNormalised() {
        #expect(TilingModel.pin(" 2 ") == "2")
        #expect(TilingModel.pin("Main") == "main")
        #expect(TilingModel.pin("DELL U2720Q") == "DELL U2720Q")
        #expect(TilingModel.pin("") == "")
        let options = TilingModel.displayOptions(pin: TilingModel.pin("Main"), screens: [])
        #expect(options.filter { $0.label == "Main display" }.count == 1)
    }

    /// An app running twice is one entry of the app menus.
    @Test func runningAppsAreListedOnce() {
        let apps = [(name: "Notes", bundleID: "com.apple.Notes"), (name: "Safari", bundleID: "com.apple.Safari"),
                    (name: "Notes", bundleID: "com.apple.Notes")]
        #expect(TilingModel.uniqueApps(apps).map(\.bundleID) == ["com.apple.Notes", "com.apple.Safari"])
    }

    @Test func everyLayoutHasAName() {
        #expect(LayoutKind.allCases.map(\.displayName) == ["Tall", "Wide", "Columns", "Monocle", "Accordion"])
    }

    /// The remaps, like every list, are written only once they differ from the ones loaded.
    @Test func aListChangesOnlyWhenItDiffers() {
        let remaps: [[String: Any]] = [["from": "caps_lock", "to": "hyper"]]
        #expect(!listChanged(remaps, since: [["from": "caps_lock", "to": "hyper"]]))
        #expect(listChanged(remaps, since: []))
        #expect(listChanged([], since: nil))
    }
}

/// What the pages offer and read: the presets, the trackpad corners, the status line.
@Suite struct SettingsPresetTests {
    @Test func presetsParse() {
        for item in MouseModel.presets.flatMap(\.items) { #expect((try? Action.parse(item.action)) != nil, "\(item.action)") }
        for action in TilingModel.shortcutActions { #expect((try? Action.parse(action)) != nil, "\(action)") }
        #expect(MouseModel.actionLabel("navigate back") == "Back")
        #expect(MouseModel.actionLabel("key cmd+left_bracket") == MouseModel.actionLabel("key cmd+["))
    }

    @Test func settingsReadTheCorners() {
        let section: [String: Any] = ["corners": ["topRight": "media mute", "topLeft": "none", "nowhere": "media next", "bottomLeft": 3]]
        #expect(TrackpadModel.corners(in: section) == [.topRight: "media mute"])
    }
}

/// The status Settings shows: the permission first, then a config error.
@Suite struct SettingsHealthTests {
    /// A login item error is not part of it.
    @Test func settingsHealth() {
        #expect(GeneralModel.health(accessibilityGranted: false, configProblem: true).text == Permissions.missingShort)
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: true).text == "Needs attention")
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: false).text == "Running")
    }

    @Test func healthIsAValueWithItsWords() {
        #expect(GeneralModel.health(accessibilityGranted: false, configProblem: true) == .permissionMissing)
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: true) == .configProblem)
        #expect(GeneralModel.health(accessibilityGranted: true, configProblem: false) == .running)
    }
}
