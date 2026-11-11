import Foundation
import Testing
@testable import HyperSpace

/// `ConfigWriter.update` against a temporary file, never the real config.
@Suite struct ConfigWriterUpdateTests {
    let url: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hyperspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    private func contents() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func editsOnlyTheTouchedKey() throws {
        try #"{ "tiling": { "gap": 4, "enabled": true }, "mouse": { "reverseScroll": true } }"#.write(to: url, atomically: true, encoding: .utf8)
        try ConfigWriter.update(url) { ConfigWriter.edit(&$0, section: "tiling") { $0["enabled"] = false } }
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let tiling = try #require(root["tiling"] as? [String: Any])
        #expect(tiling["enabled"] as? Bool == false)
        #expect(tiling["gap"] as? Int == 4)
        #expect((root["mouse"] as? [String: Any])?["reverseScroll"] as? Bool == true)
    }

    @Test func refusesAFileWithASyntaxError() throws {
        let broken = #"{ "tiling": { "gap": 4 "#
        try broken.write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: ConfigWriter.SyntaxError.self) {
            try ConfigWriter.update(url) { $0["tiling"] = ["enabled": false] }
        }
        #expect(try contents() == broken)
    }

    @Test func startsFromNothingWhenMissingOrBlank() throws {
        try ConfigWriter.update(url) { $0["tiling"] = ["enabled": true] }
        #expect(try contents().contains(#""enabled": true"#))
        try "  \n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigWriter.update(url) { $0["tiling"] = ["enabled": false] }
        #expect(try contents().contains(#""enabled": false"#))
    }

    @Test func leavesAnUnchangedFileAlone() throws {
        try ConfigWriter.update(url) { $0["tiling"] = ["gap": 4] }
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        try ConfigWriter.update(url) { _ in }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func writesThroughALink() throws {
        let target = url.deletingLastPathComponent().appendingPathComponent("dotfiles.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        try ConfigWriter.update(url) { $0["tiling"] = ["gap": 2] }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8).contains(#""gap": 2"#))
    }
}
