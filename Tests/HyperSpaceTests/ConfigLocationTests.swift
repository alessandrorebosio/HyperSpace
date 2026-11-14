import Foundation
import Testing
@testable import HyperSpace

@Suite struct ConfigLocationTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private func resolve(_ chosen: String?, existing: Set<String> = [], folders: Set<String> = []) -> String {
        ConfigLocation.resolve(chosen: chosen, home: home,
                               exists: { existing.contains($0.path) },
                               isDirectory: { folders.contains($0.path) }).path
    }

    @Test func withoutAChoice() {
        // A first launch: the standard place.
        #expect(resolve(nil) == "/Users/someone/.config/hyperspace/config.json")
        // Only the old file: it is still used.
        #expect(resolve(nil, existing: ["/Users/someone/.hyperspace/config.json"]) == "/Users/someone/.hyperspace/config.json")
        // Both: the standard one wins.
        #expect(resolve("", existing: ["/Users/someone/.hyperspace/config.json", "/Users/someone/.config/hyperspace/config.json"])
                == "/Users/someone/.config/hyperspace/config.json")
    }

    @Test func aChoiceWins() {
        #expect(resolve("~/dotfiles/hyperspace.json", existing: ["/Users/someone/.hyperspace/config.json"])
                == "/Users/someone/dotfiles/hyperspace.json")
        #expect(resolve("/etc/hs/config.json") == "/etc/hs/config.json")
        // A folder: its config.json.
        #expect(resolve("~/dotfiles/hyperspace/") == "/Users/someone/dotfiles/hyperspace/config.json")
        #expect(resolve("~/dots", folders: ["/Users/someone/dots"]) == "/Users/someone/dots/config.json")
    }

    @Test func moveReplacesAndCleansUpTheOldFolder() throws {
        try withTemporaryDirectory { dir in
            let fm = FileManager.default
            let old = dir.appendingPathComponent(".hyperspace/config.json")
            try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{ \"a\": 1 }".utf8).write(to: old)
            let new = dir.appendingPathComponent(".config/hyperspace/config.json")
            try ConfigLocation.move(from: old, to: new)
            #expect(try String(contentsOf: new, encoding: .utf8) == "{ \"a\": 1 }")
            #expect(!fm.fileExists(atPath: old.deletingLastPathComponent().path))

            // Over an existing file, which it replaces; another folder left empty stays.
            let other = dir.appendingPathComponent("dots/config.json")
            try fm.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: other)
            try ConfigLocation.move(from: new, to: other)
            #expect(try String(contentsOf: other, encoding: .utf8) == "{ \"a\": 1 }")
            #expect(fm.fileExists(atPath: new.deletingLastPathComponent().path))

            // Onto itself, or from nowhere: nothing happens.
            try ConfigLocation.move(from: other, to: other)
            #expect(fm.fileExists(atPath: other.path))
            try ConfigLocation.move(from: dir.appendingPathComponent("missing.json"), to: dir.appendingPathComponent("x/config.json"))
            #expect(!fm.fileExists(atPath: dir.appendingPathComponent("x/config.json").path))
        }
    }

    @Test func aLinkMovesAsALink() throws {
        try withTemporaryDirectory { dir in
            let fm = FileManager.default
            let target = dir.appendingPathComponent("dotfiles/config.json")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: target)
            let link = dir.appendingPathComponent("a/config.json")
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            let moved = dir.appendingPathComponent("b/config.json")
            try ConfigLocation.move(from: link, to: moved)
            #expect(try fm.destinationOfSymbolicLink(atPath: moved.path) == target.path)
            #expect(fm.fileExists(atPath: target.path))
        }
    }
}
