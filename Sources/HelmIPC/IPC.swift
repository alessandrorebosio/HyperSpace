import Foundation

/// `helmctl` <-> Helm.app protocol: one JSON line each way over a Unix domain socket.
public enum IPC {
    public struct Request: Codable, Sendable, Equatable {
        public var args: [String]
        public init(args: [String]) { self.args = args }
    }

    public struct Response: Codable, Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String

        public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }

        public static func ok(_ text: String = "") -> Response { Response(stdout: text) }
        public static func error(_ text: String, exitCode: Int32 = 1) -> Response { Response(exitCode: exitCode, stderr: text) }
    }

    /// `~/Library/Application Support/Helm/helm.sock`: per user, not world-writable like /tmp.
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Helm/helm.sock").path
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

    static func setTimeout(_ fd: Int32, seconds: Int) {
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
