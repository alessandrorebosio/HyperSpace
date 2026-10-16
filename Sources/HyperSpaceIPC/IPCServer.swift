import Foundation
import Synchronization

/// Accepts `hsctl` connections. Socket IO runs on a background queue; requests are handled
/// on the main actor, where the app state lives.
public final class IPCServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (IPC.Request) -> IPC.Response

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "hyperspace.ipc", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: (any DispatchSourceRead)?
    /// `subscribe`d clients and their events; written to in order, off the main thread.
    private let subscribers = Mutex<[(fd: Int32, events: Set<String>)]>([])
    private let events = DispatchQueue(label: "hyperspace.ipc.events")

    public init(path: String = IPC.defaultSocketPath, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard var addr = IPC.address(path) else { throw POSIXError(.ENAMETOOLONG) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        if case .success = IPCClient.send(IPC.Request(args: ["version"]), path: path, timeoutSeconds: 1) {
            close(fd)
            throw POSIXError(.EADDRINUSE) // another server is alive: don't steal its socket
        }
        unlink(path) // stale socket from a previous run
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        for subscriber in subscribers.withLock({ list in defer { list = [] }; return list }) { close(subscriber.fd) }
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        IPC.setTimeout(client, seconds: 2)

        guard let data = IPC.readMessage(from: client),
              let request = try? JSONDecoder().decode(IPC.Request.self, from: data) else {
            reply(.error("hyperspace: malformed request"), to: client)
            return
        }
        let handler = handler
        Task { @MainActor in
            let response = handler(request)
            self.queue.async { self.reply(response, to: client) }
        }
    }

    private func reply(_ response: IPC.Response, to client: Int32) {
        let sent = (try? IPC.encode(response)).map { IPC.writeAll($0, to: client) } ?? false
        if sent, let events = response.events {
            subscribers.withLock { $0.append((client, Set(events))) }
        } else {
            close(client)
        }
    }

    /// Sends one event line to the clients subscribed to it; gone ones are dropped.
    public func publish(_ event: String, _ line: String) {
        events.async { [self] in
            let data = Data((line + "\n").utf8)
            let targets = subscribers.withLock { $0.filter { $0.events.contains(event) }.map(\.fd) }
            let gone = Set(targets.filter { !IPC.writeAll(data, to: $0) })
            guard !gone.isEmpty else { return }
            subscribers.withLock { $0.removeAll { gone.contains($0.fd) } }
            for fd in gone { close(fd) }
        }
    }
}
