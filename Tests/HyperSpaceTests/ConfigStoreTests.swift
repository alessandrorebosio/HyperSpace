import Foundation
import Testing
@testable import HyperSpace

/// The config watcher, on a temporary file.
@Suite(.serialized) @MainActor struct ConfigStoreTests {
    private final class Loads {
        var results: [Bool] = []
        var last: Bool? { results.last }
    }

    /// Runs `body` with a store watching `config.json` in a temporary directory, removed afterwards.
    private func withStore(_ body: (ConfigStore, URL, Loads) async throws -> Void) async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appendingPathComponent("config.json")
            try #"{ "tiling": { "gap": 4 } }"#.write(to: url, atomically: true, encoding: .utf8)
            let store = ConfigStore(url: url, firstRetryDelay: 0.05)
            let loads = Loads()
            store.onChange = { result in
                if case .success = result { loads.results.append(true) } else { loads.results.append(false) }
            }
            try await body(store, url, loads)
        }
    }

    /// Waits on the main queue (where the watcher works) until `condition` holds, up to `timeout`.
    private func wait(_ timeout: TimeInterval = 3, until condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func loadsAtStartAndAfterAnEdit() async throws {
        try await withStore { store, url, loads in
            store.start()
            #expect(loads.results == [true])
            try #"{ "tiling": { "gap": 6 } }"#.write(to: url, atomically: false, encoding: .utf8)
            await wait { loads.results.count >= 2 }
            #expect(loads.results.count >= 2 && loads.last == true)
        }
    }

    @Test func aFileThatComesBackIsLoaded() async throws {
        try await withStore { store, url, loads in
            store.start()
            try FileManager.default.removeItem(at: url)
            // The delete is reported (a failed load), then the watcher looks for the file again.
            await wait { loads.last == false }
            #expect(loads.last == false)
            try await Task.sleep(nanoseconds: 300_000_000)
            try #"{ "tiling": { "gap": 2 } }"#.write(to: url, atomically: true, encoding: .utf8)
            await wait { loads.last == true }
            #expect(loads.last == true)
        }
    }

    @Test func aBrokenFileIsReportedAndItsFixLoaded() async throws {
        try await withStore { store, url, loads in
            store.start()
            try #"{ "tiling": "#.write(to: url, atomically: true, encoding: .utf8)
            await wait { loads.last == false }
            #expect(loads.last == false)
            try #"{ "tiling": { "gap": 2 } }"#.write(to: url, atomically: true, encoding: .utf8)
            await wait { loads.last == true }
            #expect(loads.last == true)
        }
    }
}
