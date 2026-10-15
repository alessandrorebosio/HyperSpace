import Foundation
@testable import HyperSpaceCore
import Testing

struct ConfigFileTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hyperspace-tests-\(UUID().uuidString)/hyperspace")
    }

    private func write(_ text: String, _ file: ConfigFile, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: ConfigLoader.url(file, in: dir), atomically: true, encoding: .utf8)
    }

    @Test func missingFilesMeanDefaultConfig() {
        let (config, errors) = ConfigLoader.load(from: tempDirectory())
        #expect(config == Config())
        #expect(errors.isEmpty)
    }

    @Test func eachFileFillsItsSection() throws {
        let dir = tempDirectory()
        try write("[capslock]\nhold = \"meh\"", .keyboard, in: dir)
        try write("[buttons]\nback = \"navigate.back\"", .mouse, in: dir)
        try write("enabled = true", .wm, in: dir)
        let (config, errors) = ConfigLoader.load(from: dir)
        #expect(errors.isEmpty)
        #expect(config.keyboard.capslock?.hold == "meh")
        #expect(config.mouse.buttons["back"] == .keys("navigate.back"))
        #expect(config.wm.enabled)
    }

    @Test func brokenFileKeepsItsLastGoodSectionOnly() throws {
        let dir = tempDirectory()
        try write("[capslock]\nhold = \"meh\"", .keyboard, in: dir)
        try write("[buttons]\nback = \"navigate.back\"", .mouse, in: dir)
        let good = ConfigLoader.load(from: dir).config

        try write("[capslock]\nhold = \"hyper\"", .keyboard, in: dir)
        try write("[buttons]\nback = \"nope-nope\"", .mouse, in: dir)
        let (config, errors) = ConfigLoader.load(from: dir, previous: good)
        #expect(errors.count == 1)
        #expect(errors.first?.path.hasSuffix("mouse.toml") == true)
        #expect(config.keyboard.capslock?.hold == "hyper", "the valid file is applied")
        #expect(config.mouse == good.mouse, "the broken file keeps its last good settings")
    }

    @Test func templatesAreCreatedOnceAndNeverOverwritten() throws {
        let dir = tempDirectory()
        let urls = try ConfigLoader.createTemplatesIfMissing(in: dir)
        #expect(urls.map(\.lastPathComponent) == ["keyboard.toml", "mouse.toml", "wm.toml"])
        #expect(try String(contentsOf: urls[2], encoding: .utf8) == ConfigLoader.template(.wm))

        try write("enabled = true\n", .wm, in: dir)
        try ConfigLoader.createTemplatesIfMissing(in: dir)
        #expect(ConfigLoader.load(from: dir).config.wm.enabled)
    }

    @Test(arguments: ["in-place", "atomic"])
    func watcherSeesSaves(style: String) async throws {
        let dir = tempDirectory()
        let urls = try ConfigLoader.createTemplatesIfMissing(in: dir)
        let changes = AsyncStream<Void>.makeStream()
        let watcher = ConfigWatcher(directory: dir, files: urls) { changes.continuation.yield() }
        watcher.start()
        defer { watcher.stop() }

        let url = ConfigLoader.url(.mouse, in: dir)
        let text = "[buttons]\nmiddle = \"none\"\n"
        if style == "atomic" {
            try text.write(to: url, atomically: true, encoding: .utf8) // temp file + rename
        } else {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }

        let seen = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in changes.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            changes.continuation.finish()
            return first
        }
        #expect(seen)
    }
}
