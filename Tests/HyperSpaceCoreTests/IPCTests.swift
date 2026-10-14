import Foundation
@testable import HyperSpaceIPC
import Testing

struct IPCTests {
    private func socketPath() -> String {
        // Short path: sockaddr_un is limited to 104 bytes.
        "/tmp/hs-test-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func requestRoundTrip() async throws {
        let path = socketPath()
        let server = IPCServer(path: path) { request in
            request.args == ["ping"] ? .ok("pong") : .error("unknown", exitCode: 7)
        }
        try server.start()
        defer { server.stop() }

        let ok = await Task.detached { IPCClient.send(IPC.Request(args: ["ping"]), path: path) }.value
        #expect(try ok.get() == .ok("pong"))

        let failed = await Task.detached { IPCClient.send(IPC.Request(args: ["nope"]), path: path) }.value
        #expect(try failed.get() == .error("unknown", exitCode: 7))
    }

    @Test func socketIsPrivate() throws {
        let path = socketPath()
        let server = IPCServer(path: path) { _ in .ok() }
        try server.start()
        defer { server.stop() }

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func notRunningIsDetected() {
        #expect(IPCClient.send(IPC.Request(args: ["status"]), path: socketPath()) == .failure(.notRunning))
    }
}
