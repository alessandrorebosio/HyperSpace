import Foundation
@testable import HyperSpaceCore
import Testing

struct ConfigFileTests {
    private func tempConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "hyperspace-tests-\(UUID().uuidString)/hyperspace/hyperspace.toml")
    }

    @Test func missingFileMeansDefaultConfig() throws {
        #expect(try ConfigLoader.load(from: tempConfigURL()).get() == Config())
    }

    @Test func templateIsCreatedOnceAndNeverOverwritten() throws {
        let url = tempConfigURL()
        try ConfigLoader.createTemplateIfMissing(at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == ConfigLoader.template)

        try "[wm]\nenabled = true\n".write(to: url, atomically: true, encoding: .utf8)
        try ConfigLoader.createTemplateIfMissing(at: url)
        #expect(try ConfigLoader.load(from: url).get().wm.enabled)
    }

    @Test(arguments: ["in-place", "atomic"])
    func watcherSeesSaves(style: String) async throws {
        let url = tempConfigURL()
        try ConfigLoader.createTemplateIfMissing(at: url)
        let changes = AsyncStream<Void>.makeStream()
        let watcher = ConfigWatcher(url: url) { changes.continuation.yield() }
        watcher.start()
        defer { watcher.stop() }

        let text = "[wm]\nenabled = true\n"
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
