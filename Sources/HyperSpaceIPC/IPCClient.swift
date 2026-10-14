import Foundation

public enum IPCClient {
    public enum Failure: Error, Equatable {
        case notRunning
        case io
        case badResponse
    }

    public static func send(_ request: IPC.Request, path: String = IPC.defaultSocketPath,
                            timeoutSeconds: Int = 5) -> Result<IPC.Response, Failure> {
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
        guard let reply = IPC.readMessage(from: fd) else { return .failure(.io) }
        guard let response = try? JSONDecoder().decode(IPC.Response.self, from: reply) else { return .failure(.badResponse) }
        return .success(response)
    }
}
