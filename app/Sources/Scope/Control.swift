// The control socket: how `scope status`, `scope list` and `scope reload` talk
// to the running service.
//
// Those commands run from a shell, where macOS applies the terminal's
// Accessibility permission, not Scope's, and they cannot see the service's
// record of which windows were used when. So they ask the service, which has
// both. One request per connection: a line naming the command, answered with
// text, then the connection closes.
//
// The socket lives in the per-user temporary directory, which is the same for
// launchd and for a shell whatever $TMPDIR says, and is readable by the user
// alone.

import Darwin
import Foundation

enum Control {
    static var path: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let dir = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0
            ? String(cString: buffer) : NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("scope.sock")
    }

    private static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    // MARK: Client

    /// The service's answer, or nil if no service is listening.
    static func request(_ command: String, timeout: Int = 5) -> String? {
        guard var addr = address() else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let line = command + "\n"
        guard line.withCString({ write(fd, $0, strlen($0)) }) >= 0 else { return nil }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Server

    /// Listens on a thread of its own. `handle` is called on that thread with
    /// the command line and returns the answer.
    static func serve(_ handle: @escaping (String) -> String) -> Bool {
        guard var addr = address() else {
            Log.warn("control socket path too long: \(path)")
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // A socket file left by a service that died is in the way; one that a
        // live service still answers on was checked for before this.
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            Log.warn("control socket \(path): \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }

        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var bytes: [UInt8] = []
                var byte: UInt8 = 0
                while bytes.count < 256, read(client, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
                let command = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)

                let answer = handle(command)
                answer.withCString { p in
                    var left = strlen(p), offset = 0
                    while left > 0 {
                        let n = write(client, p + offset, left)
                        if n <= 0 { break }
                        left -= n
                        offset += n
                    }
                }
                close(client)
            }
        }
        thread.name = "scope.control"
        thread.start()
        return true
    }

    static func removeSocket() {
        unlink(path)
    }
}
