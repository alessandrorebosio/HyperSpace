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
