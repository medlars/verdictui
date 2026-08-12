// Wave 7: the socket the daemon was missing.
//
// `VerdictDaemon.handle` has answered requests since Wave 6 and was tested from
// the first day — but nothing bound a socket, so no client could reach it. The
// runbook printed an `nc -U` example against a path nothing created, and the
// changelog listed the daemon under Added. A method surface without a transport
// is a library, not a service (`no.md` #34).
//
// This file is that transport and NOTHING else: it frames bytes and calls
// `handle`. Every decision about what a method MEANS stays in `VerdictDaemon`,
// so the socket, the CLI and the MCP server cannot drift into three answers.
import Foundation
import VerdictUIKernel

#if canImport(Darwin)
    import Darwin
#endif

/// Binds a unix socket and serves ``VerdictDaemon/handle(_:engine:)`` over it.
///
/// ### Framing
///
/// One JSON document per line, in both directions. Newline-delimited rather
/// than length-prefixed so the wire stays inspectable with `nc` and a
/// desynchronized stream fails visibly at the next parse instead of silently
/// consuming the wrong byte count.
///
/// ### Concurrency
///
/// Connections are served ONE AT A TIME. `handle` is `@MainActor` because
/// rendering a SwiftUI scenario is, so a second concurrent request would
/// serialize on the main actor regardless — accepting connections in parallel
/// would buy nothing and would let one client's slow render hide behind
/// another's. A queue that is honest about being a queue is easier to reason
/// about than one that pretends otherwise.
@available(macOS 13, *)
public struct DaemonTransport: Sendable {
    /// Where the socket is bound.
    public let socketPath: String
    private let engine: VerdictEngine

    public init(engine: VerdictEngine, socketPath: String = VerdictDaemon.defaultSocketPath) {
        self.engine = engine
        self.socketPath = socketPath
    }

    /// Why the transport could not start or keep running.
    public enum TransportError: Error, Equatable, CustomStringConvertible {
        case pathTooLong(path: String, limit: Int)
        case addressInUse(path: String)
        case systemCall(name: String, errno: Int32, detail: String)

        public var description: String {
            switch self {
            case .pathTooLong(let path, let limit):
                return
                    "socket path is \(path.utf8.count) bytes, over the \(limit)-byte "
                    + "sun_path limit: \(path)"
            case .addressInUse(let path):
                return
                    "another daemon is already listening on \(path) — stop it first, or "
                    + "delete the socket if no process owns it"
            case .systemCall(let name, let errno, let detail):
                return "\(name) failed (errno \(errno)): \(detail)"
            }
        }
    }

    /// `sun_path` is a fixed 104-byte buffer on Darwin, and one byte is the
    /// terminator. Exceeding it truncates the path SILENTLY at bind time, so the
    /// daemon would listen somewhere other than where it reported — checked up
    /// front and reported as itself.
    static let maximumPathLength = 103

    // MARK: - Listening

    /// Bind, listen, and serve until `shouldContinue` returns false.
    ///
    /// The socket file is removed on the way out. A caller that is killed
    /// without unwinding leaves it behind, which is why ``prepare(path:)``
    /// distinguishes a stale file from a live listener rather than refusing on
    /// the file's mere existence: a daemon that cannot restart after a crash is
    /// a daemon that needs manual cleanup on every crash.
    ///
    /// ### Why this is NOT `@MainActor`, though `handle` is
    ///
    /// `accept` and `read` BLOCK. Run on the main actor they hold it for the
    /// entire wait, and the main actor is where SwiftUI rendering happens — so
    /// the daemon would be unable to render the very scenario a request asked
    /// for. It deadlocks outright when a client shares the process, which is
    /// how this was found: the end-to-end test hung for ten minutes, because
    /// its own `connect` could never be scheduled behind the blocked `accept`.
    ///
    /// So the syscalls run OFF the main actor and only ``VerdictDaemon/handle``
    /// hops onto it. That is also the honest shape: the blocking part is I/O,
    /// and the main actor is for rendering.
    public func serve(shouldContinue: @escaping @Sendable () -> Bool = { true }) async throws {
        let listener = try Self.prepare(path: socketPath)
        defer {
            close(listener)
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        while shouldContinue() {
            let connection = await Self.acceptOffActor(listener)
            guard connection >= 0 else {
                // EINTR is a signal arriving mid-accept, not a fault: retry.
                if connection == -Int32(EINTR) { continue }
                throw TransportError.systemCall(
                    name: "accept",
                    errno: -connection,
                    detail: String(cString: strerror(-connection))
                )
            }
            defer { close(connection) }
            await serveConnection(connection)
        }
    }

    /// Block in `accept` on a background thread.
    ///
    /// Returns the connection descriptor, or the NEGATED errno on failure — one
    /// return channel, because an out-parameter across a continuation would race
    /// and a thrown error here would lose the EINTR case the caller retries.
    private static func acceptOffActor(_ listener: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let connection = accept(listener, nil, nil)
                continuation.resume(returning: connection >= 0 ? connection : -errno)
            }
        }
    }

    /// Block in `read` on a background thread.
    ///
    /// Same reasoning as ``acceptOffActor(_:)``: a blocking read held on the
    /// main actor stalls every render the daemon exists to perform.
    private static func readOffActor(_ descriptor: Int32) async -> (bytes: [UInt8], count: Int) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptor, &buffer, buffer.count)
                continuation.resume(returning: (buffer, count))
            }
        }
    }

    /// Create, bind and listen on `path`, returning the listening descriptor.
    ///
    /// Split out from ``serve(shouldContinue:)`` so a test can prove the
    /// bind-time failure modes — a path over the limit, an address already in
    /// use — without running an accept loop it would then have to stop.
    static func prepare(path: String) throws -> Int32 {
        guard path.utf8.count <= maximumPathLength else {
            throw TransportError.pathTooLong(path: path, limit: maximumPathLength)
        }

        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )

        // A leftover socket file from a killed daemon is NOT a listener. Probe
        // it: if something answers, this is a real conflict and the caller must
        // be told; if nothing does, the file is debris and removing it is the
        // difference between restarting cleanly and requiring hand cleanup.
        if FileManager.default.fileExists(atPath: path) {
            if isLive(path: path) {
                throw TransportError.addressInUse(path: path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TransportError.systemCall(
                name: "socket",
                errno: errno,
                detail: String(cString: strerror(errno))
            )
        }

        var address = Self.address(for: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let failure = errno
            close(descriptor)
            throw TransportError.systemCall(
                name: "bind",
                errno: failure,
                detail: String(cString: strerror(failure))
            )
        }

        guard listen(descriptor, 16) == 0 else {
            let failure = errno
            close(descriptor)
            try? FileManager.default.removeItem(atPath: path)
            throw TransportError.systemCall(
                name: "listen",
                errno: failure,
                detail: String(cString: strerror(failure))
            )
        }
        return descriptor
    }

    /// Whether something is actually listening on `path` right now.
    ///
    /// The question a bare `fileExists` cannot answer. Used by
    /// ``prepare(path:)`` to separate a live daemon from a crashed one's debris,
    /// and by `daemon status`, which would otherwise report a dead daemon as
    /// running for as long as its socket file survived it.
    public static func isLive(path: String) -> Bool {
        guard path.utf8.count <= maximumPathLength else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = Self.address(for: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Build the `sockaddr_un` for `path`.
    ///
    /// One helper for both call sites: `sun_path` is a fixed-size C tuple, and
    /// filling it correctly — copying no more than the buffer holds, taking a
    /// single exclusive borrow of the whole struct rather than of the field
    /// while the struct is also read — is exactly the kind of detail that goes
    /// subtly wrong in the second copy. The caller has already rejected an
    /// over-long path, so the truncation guard here is a belt on a brace.
    private static func address(for path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(maximumPathLength))
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    // MARK: - Serving one connection

    /// Read newline-delimited requests from one client until it disconnects.
    private func serveConnection(_ descriptor: Int32) async {
        var pending = Data()

        while true {
            let (buffer, count) = await Self.readOffActor(descriptor)
            if count < 0 { return }
            if count == 0 {
                // Client closed. A trailing frame with no newline is a
                // TRUNCATED request, not a request: answering it would be
                // guessing at bytes that never arrived.
                return
            }
            pending.append(contentsOf: buffer[0..<count])

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                guard !line.isEmpty else { continue }
                let reply = await Self.answer(Data(line), engine: engine)
                guard write(descriptor, [UInt8](reply), reply.count) >= 0 else { return }
            }
        }
    }

    /// Decode one frame, answer it, and encode the reply.
    ///
    /// Every failure path returns a well-formed `DaemonResponse` with
    /// `ok: false` rather than closing the connection or writing nothing. A
    /// client that sent malformed JSON must get an answer saying so — silence is
    /// indistinguishable from a hung daemon, and that is the one diagnosis a
    /// caller cannot make from the outside.
    @MainActor
    static func answer(_ line: Data, engine: VerdictEngine) async -> Data {
        let response: DaemonResponse
        do {
            let request = try VerdictDaemon.decode(line)
            response = await VerdictDaemon.handle(request, engine: engine)
        } catch {
            response = DaemonResponse(
                ok: false,
                id: nil,
                result: nil,
                error: "malformed request: \(error)"
            )
        }
        // Encoding a response cannot realistically fail — but if it did, the
        // client must still receive a parseable line, so the fallback is
        // hand-built rather than a rethrow that would hang the caller.
        if let encoded = try? VerdictDaemon.encode(response) {
            return encoded
        }
        return Data(#"{"ok":false,"error":"response could not be encoded"}"# .utf8 + [0x0A])
    }
}
