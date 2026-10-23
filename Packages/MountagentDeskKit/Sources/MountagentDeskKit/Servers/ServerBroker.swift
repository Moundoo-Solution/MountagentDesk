import Darwin
import Foundation

/// How `mountagent-server` reaches the app. The helper an agent runs holds nothing and
/// decides nothing: it sends its run's token, the server and the command over a Unix socket
/// in the data folder, and the app, which issued that token for one agent run, checks them
/// against its own state (not files an agent could have edited) and runs ssh itself.
public enum ServerBroker {
    /// Set in an agent's environment for the length of one run.
    public static let tokenVariable = "MOUNTAGENT_HELPER_TOKEN"
    static let socketName = "helper.sock"

    public struct Request: Codable, Sendable, Equatable {
        public var token: String
        /// `nil` lists the servers the run may read.
        public var server: String?
        public var command: String

        public init(token: String, server: String?, command: String) {
            self.token = token
            self.server = server
            self.command = command
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        /// What the command printed.
        public var output: String
        /// Why nothing ran, or why the run stopped; shown on stderr.
        public var error: String?
        public var status: Int32

        public init(output: String = "", error: String? = nil, status: Int32) {
            self.output = output
            self.error = error
            self.status = status
        }

        public static func refused(_ message: String) -> Reply {
            Reply(error: message, status: 1)
        }
    }

    /// In the data folder, or, when that path is too long for a Unix socket (104 bytes), in
    /// the user's own temporary folder under a name derived from it.
    public static func socketURL(in root: URL) -> URL {
        let url = root.appendingPathComponent(socketName)
        guard url.path.utf8.count >= 100 else { return url }
        // FNV-1a: stable across launches, unlike hashValue.
        let hash = root.standardizedFileURL.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return FileManager.default.temporaryDirectory.appendingPathComponent("mountagent-\(String(hash, radix: 36)).sock")
    }

    enum Failure: Error {
        case path, socket(Int32), connect(Int32), reply
    }

    /// Sends a request and waits for the reply (in the helper).
    public static func send(_ request: Request, root: URL) throws -> Reply {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        defer { close(descriptor) }
        noSignalOnWrite(descriptor)
        var address = try address(of: socketURL(in: root).path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure.connect(errno) }
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        guard writeAll(descriptor, line) else { throw Failure.reply }
        shutdown(descriptor, SHUT_WR)
        guard let data = readAll(descriptor, limit: 4 << 20) else { throw Failure.reply }
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    /// Listens for helpers. `handle` runs on a background thread for each request; only
    /// processes of the same user can connect (the socket is 0600 and the peer is checked).
    public final class Listener: @unchecked Sendable {
        private let path: String
        private let handle: @Sendable (Request) -> Reply
        private let lock = NSLock()
        private var descriptor: Int32 = -1
        /// The socket file this listener made, so stopping never removes a newer copy's
        /// (an app opened again while this one was still quitting).
        private var identity: (device: dev_t, inode: ino_t)?

        public init(root: URL, handle: @escaping @Sendable (Request) -> Reply) {
            path = ServerBroker.socketURL(in: root).path
            self.handle = handle
        }

        public func start() throws {
            unlink(path)
            let listening = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listening >= 0 else { throw Failure.socket(errno) }
            var address = try ServerBroker.address(of: path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(listening, 16) == 0 else {
                let code = errno
                close(listening)
                throw Failure.socket(code)
            }
            var info = stat()
            let made = stat(path, &info) == 0 ? (device: info.st_dev, inode: info.st_ino) : nil
            lock.withLock {
                descriptor = listening
                identity = made
            }
            let thread = Thread { [self] in acceptLoop(listening) }
            thread.name = "mountagent-server listener"
            thread.start()
        }

        public func stop() {
            let (listening, made) = lock.withLock { () -> (Int32, (device: dev_t, inode: ino_t)?) in
                defer {
                    descriptor = -1
                    identity = nil
                }
                return (descriptor, identity)
            }
            guard listening >= 0 else { return }
            close(listening)
            var info = stat()
            if let made, stat(path, &info) == 0, info.st_dev == made.device, info.st_ino == made.inode { unlink(path) }
        }

        private func acceptLoop(_ listening: Int32) {
            while true {
                let client = accept(listening, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
            }
        }

        private func serve(_ client: Int32) {
            defer { close(client) }
            ServerBroker.noSignalOnWrite(client)
            var user: uid_t = 0
            var group: gid_t = 0
            guard getpeereid(client, &user, &group) == 0, user == getuid(),
                  let data = ServerBroker.readAll(client, limit: 1 << 16),
                  let request = try? JSONDecoder().decode(Request.self, from: data)
            else { return }
            let reply = handle(request)
            if let encoded = try? JSONEncoder().encode(reply) { _ = ServerBroker.writeAll(client, encoded) }
        }
    }

    // MARK: Sockets

    static func address(of path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.path }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A closed peer makes a write fail instead of killing the process with SIGPIPE.
    static func noSignalOnWrite(_ descriptor: Int32) {
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Everything until the peer closes (or, for a request, until its newline).
    static func readAll(_ descriptor: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(buffer, count: count)
            if data.count > limit { return nil }
            if let newline = data.firstIndex(of: 0x0A) { return data[..<newline] }
        }
    }
}
