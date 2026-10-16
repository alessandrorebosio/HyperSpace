import Foundation

public enum IPCClient {
    public enum Failure: Error, Equatable {
        case notRunning
        case io
        case badResponse
    }

    public static func send(_ request: IPC.Request, path: String = IPC.defaultSocketPath,
                            timeoutSeconds: Int = 5) -> Result<IPC.Response, Failure> {
        send(request, path: path, timeoutSeconds: timeoutSeconds, events: nil)
    }

    /// Sends the request; a response with `events` is followed by `event` lines until
    /// HyperSpace quits (then this returns).
    public static func send(_ request: IPC.Request, path: String = IPC.defaultSocketPath, timeoutSeconds: Int = 5,
                            events: ((String) -> Void)?) -> Result<IPC.Response, Failure> {
        guard var addr = IPC.address(path) else { return .failure(.io) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.io) }
        defer { close(fd) }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return .failure(.notRunning) }
        IPC.setTimeout(fd, seconds: timeoutSeconds)

        guard let data = try? IPC.encode(request), IPC.writeAll(data, to: fd) else { return .failure(.io) }
        var lines = IPC.Lines(fd)
        guard let reply = lines.next() else { return .failure(.io) }
        guard let response = try? JSONDecoder().decode(IPC.Response.self, from: reply) else { return .failure(.badResponse) }
        guard response.events != nil, let events else { return .success(response) }
        IPC.setTimeout(fd, seconds: 0) // events come whenever they happen
        if !response.stdout.isEmpty { events(response.stdout) }
        while let line = lines.next() { events(String(decoding: line, as: UTF8.self)) }
        return .success(response)
    }
}
