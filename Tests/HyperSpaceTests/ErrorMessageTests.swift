import Foundation
import Testing
@testable import HyperSpace

/// What the menu shows for a config that does not load.
@Suite struct ErrorMessageTests {
    private func loadError(_ json: String) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hyperspace-\(UUID().uuidString).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try Config.load(from: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func wrongTypeNamesThePlace() {
        let message = loadError(#"{ "keyboard": { "bindings": [ { "keys": "hyper+h", "action": "focus left" }, { "keys": 3, "action": "float" } ] } }"#)
        #expect(message == "keyboard.bindings[1].keys: expected text")
    }

    @Test func missingKeyIsNamed() {
        let message = loadError(#"{ "keyboard": { "bindings": [ { "keys": "hyper+h" } ] } }"#)
        #expect(message == #"keyboard.bindings[0]: missing "action""#)
    }

    @Test func brokenJSONSaysSo() {
        #expect(loadError(#"{ "tiling": "#)?.hasPrefix("invalid JSON") == true)
    }

    @Test func menuTitleIsShortened() {
        let problem = StatusMenu.Problem.config(String(repeating: "x", count: 80) + "\nsecond line")
        #expect(problem.menuTitle.count == "Config error: ".count + 48)
        #expect(problem.menuTitle.hasSuffix("…"))
        #expect(StatusMenu.Problem.config("short").menuTitle == "Config error: short")
    }
}
