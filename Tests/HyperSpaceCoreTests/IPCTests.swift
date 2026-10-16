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

    @Test func subscribersGetTheirEvents() async throws {
        let path = socketPath()
        let server = IPCServer(path: path) { _ in IPC.Response(stdout: "initial", events: ["a"]) }
        try server.start()
        defer { server.stop() }

        let lines = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
            Thread.detachNewThread {
                var lines: [String] = []
                _ = IPCClient.send(IPC.Request(args: ["subscribe"]), path: path) { line in
                    lines.append(line)
                    if lines.count == 2 { server.stop() } // closes the stream
                }
                done.resume(returning: lines)
            }
            Thread.detachNewThread {
                usleep(200_000)
                server.publish("b", "not subscribed")
                server.publish("a", "event")
            }
        }
        #expect(lines == ["initial", "event"])
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
