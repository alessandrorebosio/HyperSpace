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
}

/// The problems the menu bar reports, with the event tap among them.
@Suite struct TapProblemTests {
    @Test func theTapProblemSitsBetweenThePermissionAndTheConfig() {
        #expect(StatusMenu.problems(permissionMissing: true, tapUnavailable: true, configError: "bad")
            == [.permission, .tap, .config("bad")])
        #expect(StatusMenu.problems(permissionMissing: false, tapUnavailable: true, configError: nil) == [.tap])
        #expect(StatusMenu.Problem.tap.menuTitle == "Event tap unavailable")
    }
}

/// The menu bar item: its title and its VoiceOver text.
@Suite struct StatusMenuTextTests {
    /// The bar's VoiceOver text names the app when no workspace is focused, not an empty workspace.
    @Test func menuBarDescriptionWithoutAFocusedWorkspace() {
        #expect(StatusMenu.workspacesImage(names: ["1", "2"], focused: 5, locked: false, problem: false)
            .accessibilityDescription == "HyperSpace")
        #expect(StatusMenu.workspacesImage(names: ["1", "web"], focused: 1, locked: false, problem: false)
            .accessibilityDescription == "Workspace web")
        #expect(StatusMenu.accessibilityDescription(workspace: "", locked: true, problem: false) == "HyperSpace, keyboard locked")
    }

    @Test func menuTitleIsShortened() {
        let problem = StatusMenu.Problem.config(String(repeating: "x", count: 80) + "\nsecond line")
        #expect(problem.menuTitle.count == "Config error: ".count + 48)
        #expect(problem.menuTitle.hasSuffix("…"))
        #expect(StatusMenu.Problem.config("short").menuTitle == "Config error: short")
    }
}
