import Foundation
import Testing
@testable import HyperSpace

// Reading, writing, locating and watching config.json: always a file in a temporary directory.

@Suite struct ConfigWriterFormatTests {
    private let sample: [String: Any] = [
        "tiling": ["enabled": true, "gap": 8, "layout": "tall"] as [String: Any],
        "mouse": ["reverseScroll": false, "dragModifier": "cmd"] as [String: Any],
        "keyboard": [
            "remap": [["from": "caps_lock", "to": "hyper", "keyboard": "builtin"] as [String: Any]],
            "bindings": [["keys": "cmd+a", "action": "shell say \"hi\" \\ a/b"] as [String: Any]],
        ] as [String: Any],
    ]

    private func index(_ needle: String, in text: String) -> Int {
        text.range(of: needle)?.lowerBound.utf16Offset(in: text) ?? -1
    }

    @Test func roundTripsThroughJSON() throws {
        let text = ConfigWriter.text(for: sample)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: parsed).isEqual(to: sample))
    }

    @Test func topLevelKeysFollowTheKeyOrder() {
        let text = ConfigWriter.text(for: sample)
        let keyboard = index("\"keyboard\"", in: text)
        let mouse = index("\"mouse\"", in: text)
        let tiling = index("\"tiling\"", in: text)
        #expect(keyboard >= 0 && keyboard < mouse && mouse < tiling)
    }

    @Test func keyboardComesLastInsideARemapRule() {
        let text = ConfigWriter.text(for: ["keyboard": ["remap": [["keyboard": "builtin", "to": "hyper", "from": "caps_lock"]]]])
        #expect(text.contains("{ \"from\": \"caps_lock\", \"to\": \"hyper\", \"keyboard\": \"builtin\" }"))
    }

    /// Keys the order does not know come after the known ones, alphabetically; "keyboard"
    /// inside a rule still comes after them.
    @Test func unknownKeysComeAfterTheKnownOnes() {
        let text = ConfigWriter.text(for: ["tiling": ["zeta": 1, "alpha": 2, "gap": 3]])
        let gap = index("\"gap\"", in: text), alpha = index("\"alpha\"", in: text), zeta = index("\"zeta\"", in: text)
        #expect(gap >= 0 && gap < alpha && alpha < zeta)
        let rule = ConfigWriter.text(for: ["keyboard": ["remap": [["keyboard": "builtin", "zzz": 1, "from": "a"]]]])
        #expect(rule.contains("{ \"from\": \"a\", \"zzz\": 1, \"keyboard\": \"builtin\" }"))
    }

    @Test func flatObjectsInArraysStayOnOneLine() {
        let text = ConfigWriter.text(for: sample)
        let line = text.split(separator: "\n").first { $0.contains("cmd+a") }
        #expect(line?.contains("{ \"keys\"") == true && line?.contains("}") == true)
    }

    @Test func nestedObjectsAreIndented() {
        let text = ConfigWriter.text(for: ["tiling": ["scratchpad": ["width": 0.5]]])
        #expect(text == """
        {
          "tiling": {
            "scratchpad": {
              "width": 0.5
            }
          }
        }

        """)
    }

    /// An object in a list that holds a list or an object is not flat: one key per line.
    @Test func nestedObjectsInArraysSpreadOverLines() throws {
        let root: [String: Any] = ["tiling": ["workspaces": [["name": "a", "tags": ["x"]] as [String: Any]]]]
        let text = ConfigWriter.text(for: root)
        #expect(!text.contains("{ \"name\""))
        #expect(text.contains("\n        \"name\": \"a\",\n"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(NSDictionary(dictionary: parsed).isEqual(to: root))
    }

    @Test func emptyContainers() {
        #expect(ConfigWriter.text(for: [:]) == "{}\n")
        #expect(ConfigWriter.text(for: ["tiling": [String: Any](), "floating": [String]()]).contains("\"floating\": []"))
    }

    @Test func escapesQuotesAndBackslashesButNotSlashes() {
        let text = ConfigWriter.text(for: ["a": "say \"hi\" \\ a/b"])
        #expect(text.contains("\"say \\\"hi\\\" \\\\ a/b\""))
    }

    @Test func booleansAreNotNumbers() {
        let text = ConfigWriter.text(for: ["on": true, "off": false, "one": 1])
        #expect(text.contains("\"on\": true") && text.contains("\"off\": false") && text.contains("\"one\": 1"))
    }
}

/// `ConfigWriter.update` against a temporary file, never the real config.
@Suite struct ConfigWriterUpdateTests {
    /// Runs `body` with `config.json` in a temporary directory (not created), removed afterwards.
    private func withConfigFile(_ body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { dir in try body(dir.appendingPathComponent("config.json")) }
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func editsOnlyTheTouchedKey() throws {
        try withConfigFile { url in
            try #"{ "tiling": { "gap": 4, "enabled": true }, "mouse": { "reverseScroll": true } }"#.write(to: url, atomically: true, encoding: .utf8)
            try ConfigWriter.update(url) { ConfigWriter.edit(&$0, section: "tiling") { $0["enabled"] = false } }
            let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let tiling = try #require(root["tiling"] as? [String: Any])
            #expect(tiling["enabled"] as? Bool == false)
            #expect(tiling["gap"] as? Int == 4)
            #expect((root["mouse"] as? [String: Any])?["reverseScroll"] as? Bool == true)
        }
    }

    @Test func refusesAFileWithASyntaxError() throws {
        try withConfigFile { url in
            let broken = #"{ "tiling": { "gap": 4 "#
            try broken.write(to: url, atomically: true, encoding: .utf8)
            #expect(throws: ConfigWriter.SyntaxError.self) {
                try ConfigWriter.update(url) { $0["tiling"] = ["enabled": false] }
            }
            #expect(try contents(url) == broken)
        }
    }

    @Test func startsFromNothingWhenMissingOrBlank() throws {
        try withConfigFile { url in
            try ConfigWriter.update(url) { $0["tiling"] = ["enabled": true] }
            #expect(try contents(url).contains(#""enabled": true"#))
            try "  \n".write(to: url, atomically: true, encoding: .utf8)
            try ConfigWriter.update(url) { $0["tiling"] = ["enabled": false] }
            #expect(try contents(url).contains(#""enabled": false"#))
        }
    }

    /// No write at all: an atomic write would put a new file (a new inode) in its place.
    @Test func leavesAnUnchangedFileAlone() throws {
        try withConfigFile { url in
            try ConfigWriter.update(url) { $0["tiling"] = ["gap": 4] }
            func identity() throws -> (Int?, Date?) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return ((attributes[.systemFileNumber] as? NSNumber)?.intValue, attributes[.modificationDate] as? Date)
            }
            let before = try identity()
            try ConfigWriter.update(url) { _ in }
            let after = try identity()
            #expect(before.0 != nil && before.0 == after.0 && before.1 == after.1)
            // A change is written (the check above can tell).
            try ConfigWriter.update(url) { $0["tiling"] = ["gap": 6] }
            #expect(try identity().0 != before.0)
        }
    }

    @Test func writesThroughALink() throws {
        try withConfigFile { url in
            let target = url.deletingLastPathComponent().appendingPathComponent("dotfiles.json")
            try "{}".write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            try ConfigWriter.update(url) { $0["tiling"] = ["gap": 2] }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
            #expect(try String(contentsOf: target, encoding: .utf8).contains(#""gap": 2"#))
        }
    }

    /// The one parse behind `readIfValid` and `update`: missing or blank is empty, broken is nil.
    @Test func parsesMissingBlankBrokenAndValid() throws {
        try withConfigFile { url in
            #expect(ConfigWriter.parseFile(url).root?.isEmpty == true)
            try " \n".write(to: url, atomically: true, encoding: .utf8)
            #expect(ConfigWriter.parseFile(url).root?.isEmpty == true)
            try "[1]".write(to: url, atomically: true, encoding: .utf8)
            #expect(ConfigWriter.parseFile(url).root == nil)
            try #"{ "tiling": { "gap": 4 }"#.write(to: url, atomically: true, encoding: .utf8)
            #expect(ConfigWriter.parseFile(url).root == nil)
            try #"{ "tiling": { "gap": 4 } }"#.write(to: url, atomically: true, encoding: .utf8)
            #expect(ConfigWriter.section("tiling", of: try #require(ConfigWriter.parseFile(url).root))["gap"] as? Int == 4)
        }
    }
}

/// Blank, missing, unreadable and linked files, for the loader and the writer alike.
@Suite struct ConfigFileEdgeCaseTests {
    @Test func aBlankFileIsAnEmptyConfigForTheLoaderToo() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            for text in ["", " \n\t\n"] {
                try text.write(to: url, atomically: true, encoding: .utf8)
                let loaded = try Config.load(from: url)
                #expect(loaded.remaps.isEmpty && loaded.tap.eventMask == 0 && loaded.tiling == TilingConfig())
                #expect(ConfigWriter.parseFile(url).root?.isEmpty == true)
            }
            try "{".write(to: url, atomically: true, encoding: .utf8)
            #expect(configErrorMessage { try Config.load(from: url) }?.hasPrefix("invalid JSON") == true)
        }
    }

    /// A file that is there but cannot be read is not an empty one: saving a setting over it
    /// would replace everything in it with that one setting.
    @Test func anUnreadableFileIsNotEditedAsEmpty() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            let text = #"{ "tiling": { "gap": 4 } }"#
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            // Root reads anything: nothing to check then.
            guard (try? Data(contentsOf: url)) == nil else { return }

            let parsed = ConfigWriter.parseFile(url)
            #expect(parsed.data == nil && parsed.root == nil)
            #expect(throws: ConfigWriter.UnreadableError.self) { try ConfigWriter.update(url) { $0["mouse"] = ["reverseScroll": true] } }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try String(contentsOf: url, encoding: .utf8) == text)
        }
    }

    @Test func aMissingFileIsStillAnEmptyOne() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            #expect(ConfigWriter.parseFile(url).root?.isEmpty == true)
            try ConfigWriter.update(url) { $0["tiling"] = ["gap": 2] }
            #expect(try String(contentsOf: url, encoding: .utf8).contains(#""gap": 2"#))
        }
    }

    @Test func tellsAMissingFileFromOtherErrors() {
        #expect(ConfigWriter.isMissingFile(CocoaError(.fileReadNoSuchFile)))
        #expect(ConfigWriter.isMissingFile(POSIXError(.ENOENT)))
        #expect(!ConfigWriter.isMissingFile(CocoaError(.fileReadNoPermission)))
        #expect(!ConfigWriter.isMissingFile(POSIXError(.EACCES)))
    }

    /// A link whose file is not there yet (dotfiles not cloned): a write goes where it points,
    /// and the link stays a link.
    @Test func writesThroughALinkWhoseFileIsMissing() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            let target = dir.appendingPathComponent("dotfiles/config.json")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "dotfiles/config.json")
            #expect(url.linkTarget.path == target.standardizedFileURL.path)

            try ConfigWriter.update(url) { $0["tiling"] = ["gap": 2] }
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == "dotfiles/config.json")
            #expect(try String(contentsOf: target, encoding: .utf8).contains(#""gap": 2"#))
        }
    }

    @Test func linkTargetFollowsChainsAndLeavesFilesAlone() throws {
        try withTemporaryDirectory { dir in
            let file = dir.appendingPathComponent("real.json")
            try "{}".write(to: file, atomically: true, encoding: .utf8)
            #expect(file.linkTarget == file)
            #expect(dir.appendingPathComponent("nothing.json").linkTarget.lastPathComponent == "nothing.json")

            let first = dir.appendingPathComponent("first.json"), second = dir.appendingPathComponent("second.json")
            try FileManager.default.createSymbolicLink(at: second, withDestinationURL: file)
            try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "second.json")
            #expect(first.linkTarget.path == file.standardizedFileURL.path)

            // A loop of links ends.
            let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
            try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: "b")
            try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: "a")
            #expect(["a", "b"].contains(a.linkTarget.lastPathComponent))
        }
    }
}

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

    /// "~" and "~/…" are this user's home; "~name" is another user's, never `home` + "name".
    @Test func onlyTheBareTildeIsTheHomeFolder() {
        #expect(resolve("~/dotfiles/hs.json") == "/Users/someone/dotfiles/hs.json")
        #expect(!resolve("~nobody-hyperspace/hs.json").hasPrefix("/Users/someonenobody"))
    }

    @Test func abbreviatedPathUsesTheTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(home.appendingPathComponent(".config/hyperspace/config.json").abbreviatedPath == "~/.config/hyperspace/config.json")
        #expect(URL(fileURLWithPath: "/tmp/x.json").abbreviatedPath == "/tmp/x.json")
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

/// What a store reported, load after load (true: the config loaded).
private final class Loads {
    var results: [Bool] = []
    var last: Bool? { results.last }

    /// A store watching `url`, reporting here.
    @MainActor
    func store(_ url: URL) -> ConfigStore {
        let store = ConfigStore(url: url, firstRetryDelay: 0.05)
        store.onChange = { [self] result in
            if case .success = result { results.append(true) } else { results.append(false) }
        }
        return store
    }
}

/// The config watcher, on a temporary file.
@Suite(.serialized) @MainActor struct ConfigStoreTests {
    /// Runs `body` with a store watching `config.json` in a temporary directory, removed afterwards.
    private func withStore(_ body: (ConfigStore, URL, Loads) async throws -> Void) async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            try #"{ "tiling": { "gap": 4 } }"#.write(to: url, atomically: true, encoding: .utf8)
            let loads = Loads()
            try await body(loads.store(url), url, loads)
        }
    }

    @Test func loadsAtStartAndAfterAnEdit() async throws {
        try await withStore { store, url, loads in
            store.start()
            #expect(loads.results == [true])
            try #"{ "tiling": { "gap": 6 } }"#.write(to: url, atomically: false, encoding: .utf8)
            await waitUntil { loads.results.count >= 2 }
            #expect(loads.results.count >= 2 && loads.last == true)
        }
    }

    @Test func aFileThatComesBackIsLoaded() async throws {
        try await withStore { store, url, loads in
            store.start()
            try FileManager.default.removeItem(at: url)
            // The delete is reported (a failed load), then the watcher looks for the file again.
            await waitUntil { loads.last == false }
            #expect(loads.last == false)
            try #"{ "tiling": { "gap": 2 } }"#.write(to: url, atomically: true, encoding: .utf8)
            await waitUntil { loads.last == true }
            #expect(loads.last == true)
        }
    }

    @Test func aBrokenFileIsReportedAndItsFixLoaded() async throws {
        try await withStore { store, url, loads in
            store.start()
            try #"{ "tiling": "#.write(to: url, atomically: true, encoding: .utf8)
            await waitUntil { loads.last == false }
            #expect(loads.last == false)
            try #"{ "tiling": { "gap": 2 } }"#.write(to: url, atomically: true, encoding: .utf8)
            await waitUntil { loads.last == true }
            #expect(loads.last == true)
        }
    }
}

/// The watcher and the default config, with a linked config in a temporary directory.
@Suite(.serialized) @MainActor struct ConfigStoreLinkTests {
    /// The default config of a link whose file is missing is written where the link points.
    @Test func theDefaultConfigGoesThroughADanglingLink() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            let target = dir.appendingPathComponent("dotfiles/config.json")
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "dotfiles/config.json")
            let loads = Loads()
            let store = loads.store(url)
            store.start()
            #expect(loads.results == [true])
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == "dotfiles/config.json")
            #expect(try String(contentsOf: target, encoding: .utf8) == DefaultConfig.json)
        }
    }

    /// Pointing the link at another file changes nothing on the file it pointed at: the link
    /// itself is watched.
    @Test func reloadsWhenTheLinkPointsElsewhere() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            let good = dir.appendingPathComponent("good.json"), broken = dir.appendingPathComponent("broken.json")
            try #"{ "tiling": { "gap": 4 } }"#.write(to: good, atomically: true, encoding: .utf8)
            try "{".write(to: broken, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: good)
            let loads = Loads()
            let store = loads.store(url)
            store.start()
            #expect(loads.results == [true])

            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: broken)
            await waitUntil { loads.last == false }
            #expect(loads.last == false)

            // And the file it points at now is the one followed.
            try #"{ "tiling": { "gap": 6 } }"#.write(to: broken, atomically: false, encoding: .utf8)
            await waitUntil { loads.last == true }
            #expect(loads.last == true)
        }
    }
}
