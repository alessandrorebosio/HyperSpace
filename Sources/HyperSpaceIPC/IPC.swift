import Foundation

/// `hsctl` <-> HyperSpace.app protocol: one JSON line each way over a Unix domain socket.
/// A response with `events` (`subscribe`) keeps the connection: one JSON line per event follows.
public enum IPC {
    public struct Request: Codable, Sendable, Equatable {
        public var args: [String]
        public init(args: [String]) { self.args = args }
    }

    public struct Response: Codable, Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
        /// The events the client now gets, as they happen.
        public var events: [String]?

        public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "", events: [String]? = nil) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.events = events
        }

        public static func ok(_ text: String = "") -> Response { Response(stdout: text) }
        public static func error(_ text: String, exitCode: Int32 = 1) -> Response { Response(exitCode: exitCode, stderr: text) }
    }

    /// `~/Library/Application Support/HyperSpace/hyperspace.sock`: per user, not world-writable like /tmp.
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/HyperSpace/hyperspace.sock").path
    }

    static let maxMessageSize = 64 * 1024

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Reads until newline or EOF. The socket has a receive timeout set by the caller.
    static func readMessage(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxMessageSize {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
            if buffer[n - 1] == UInt8(ascii: "\n") { break }
        }
        return data.isEmpty ? nil : data
    }

    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// A line-by-line reader: messages can arrive several in one read.
    struct Lines {
        let fd: Int32
        private var buffer = Data()

        init(_ fd: Int32) { self.fd = fd }

        /// The next line, without its newline; nil at EOF, on error or timeout.
        mutating func next() -> Data? {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                if let end = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    defer { buffer.removeSubrange(...end) }
                    return buffer[..<end]
                }
                guard buffer.count < maxMessageSize else { return nil }
                let n = read(fd, &chunk, chunk.count)
                guard n > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<n])
            }
        }
    }

    static func setTimeout(_ fd: Int32, seconds: Int) {
        var on: Int32 = 1 // a client gone mid-write is an error, not a SIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Fills a sockaddr_un for `path`; nil if the path doesn't fit (104 bytes on macOS).
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }
}
