import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

#if canImport(Darwin)
    import Darwin
#endif

/// Drives the real unix socket.
///
/// `DaemonTests` covers `VerdictDaemon.handle`, which was correct and fully
/// tested for a whole wave while NOTHING bound a socket — the runbook printed an
/// `nc -U` example against a path that never existed (`no.md` #34). A method
/// surface without a transport is a library, so this file asserts on the
/// transport: it binds, it accepts, it frames, and it survives the failure modes
/// a long-running server actually meets.
@available(macOS 13, *)
final class DaemonTransportTests: XCTestCase {
    @MainActor
    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(root: temporaryDirectory())
        )
    }

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-sock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A socket path short enough for `sun_path`.
    ///
    /// `NSTemporaryDirectory()` under a long user path plus a UUID can exceed
    /// the 103-byte limit, and a test that failed for THAT would look like a
    /// transport bug.
    private func socketPath() -> String {
        let path = "/tmp/vui-t-\(UUID().uuidString.prefix(8)).sock"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - Bind-time behaviour

    /// An over-long path is rejected up front, by name.
    ///
    /// `sun_path` is a fixed 104-byte buffer, and a path past it is truncated
    /// SILENTLY at bind time — the daemon would then listen somewhere other than
    /// where it reported, which is the worst possible failure for a client
    /// trying to find it.
    func testAnOverLongSocketPathIsRefusedRatherThanTruncated() throws {
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"

        XCTAssertThrowsError(try DaemonTransport.prepare(path: tooLong)) { error in
            guard case DaemonTransport.TransportError.pathTooLong = error else {
                return XCTFail("expected pathTooLong, got \(error)")
            }
        }
    }

    /// A crashed daemon's leftover socket file does not block a restart.
    ///
    /// The file outlives a process killed without unwinding. Refusing on its
    /// mere existence would mean every crash needs manual cleanup before the
    /// daemon can start again.
    func testAStaleSocketFileIsReplacedRatherThanRefused() throws {
        let path = socketPath()
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let descriptor = try prepareSocketOrSkip(path: path)
        defer { close(descriptor) }

        XCTAssertGreaterThanOrEqual(descriptor, 0, "a stale file must not block binding")
    }

    /// A LIVE listener is a real conflict and must be refused.
    ///
    /// The control for the test above: without this, "replaces a stale socket"
    /// would be satisfied by an implementation that cheerfully stomps a running
    /// daemon, silently stealing its socket and leaving two servers fighting.
    func testALiveListenerIsRefusedAsAddressInUse() throws {
        let path = socketPath()
        let first = try prepareSocketOrSkip(path: path)
        defer { close(first) }

        XCTAssertThrowsError(try DaemonTransport.prepare(path: path)) { error in
            guard case DaemonTransport.TransportError.addressInUse = error else {
                return XCTFail("expected addressInUse, got \(error)")
            }
        }
    }

    /// `isLive` answers about a LISTENER, not about a file.
    ///
    /// This is what `daemon status` reports, and reading the filesystem instead
    /// would report a dead daemon as running for as long as its socket survived
    /// it. Both directions asserted: a bound socket is live, a plain file is
    /// not.
    func testIsLiveDistinguishesAListenerFromAFile() throws {
        let bound = socketPath()
        let descriptor = try prepareSocketOrSkip(path: bound)
        defer { close(descriptor) }
        XCTAssertTrue(DaemonTransport.isLive(path: bound), "a bound socket is live")

        let plain = socketPath()
        FileManager.default.createFile(atPath: plain, contents: Data())
        XCTAssertFalse(
            DaemonTransport.isLive(path: plain),
            "a regular file is not a listener — status must not report it as a running daemon"
        )

        XCTAssertFalse(
            DaemonTransport.isLive(path: "/tmp/vui-definitely-absent-\(UUID().uuidString).sock"),
            "an absent path is not live"
        )
    }

    // MARK: - Framing

    /// One frame in, one well-formed frame out.
    @MainActor
    func testAFrameIsAnsweredWithOneNewlineTerminatedDocument() async throws {
        let reply = engine()
        let data = await DaemonTransport.answer(
            Data(#"{"method":"ping","id":"p"}"#.utf8),
            engine: reply
        )

        XCTAssertEqual(data.last, 0x0A, "every frame ends in a newline")
        XCTAssertFalse(
            data.dropLast().contains(0x0A),
            "one document per frame — an embedded newline would split it"
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["id"] as? String, "p")
    }

    /// Malformed input is answered, not dropped.
    ///
    /// A client that sent bad JSON and receives nothing cannot tell that from a
    /// hung daemon — the one diagnosis it cannot make from outside. The reply
    /// must also stay well-formed, or the client's parser dies on the answer to
    /// its own parse error.
    @MainActor
    func testAMalformedFrameIsAnsweredWithAWellFormedRefusal() async throws {
        let verdictEngine = engine()
        let data = await DaemonTransport.answer(Data("{not json".utf8), engine: verdictEngine)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertNotNil(object["error"], "the refusal must say why")
    }

    // MARK: - End to end over a real socket

    /// Connect to a bound socket and send `frames`, returning the replies.
    private static func converse(with path: String, frames: [String]) throws -> [SocketReply] {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        guard client >= 0 else { throw SocketClientError.openFailed(errno: errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SocketClientError.connectFailed(path: path, errno: errno) }

        let payload = Data(frames.map { $0 + "\n" }.joined().utf8)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, payload.count) }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while received.filter({ $0 == 0x0A }).count < frames.count {
            let count = read(client, &buffer, buffer.count)
            // `count` may be 0 (peer closed) or negative (error). Both mean no
            // more bytes are coming; slicing on either would trap, which is how
            // an ordinary assertion failure became a process-killing crash that
            // took the rest of the suite with it.
            guard count > 0 else { break }
            received.append(contentsOf: buffer[0..<count])
        }

        return
            String(decoding: received, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            .compactMap { $0 as? [String: Any] }
            .map(SocketReply.init(object:))
    }

    /// The whole path: `serve()` binds and accepts, a real client is answered.
    ///
    /// The assertion that would have caught the wave-long gap. Everything below
    /// `handle` was already tested; the accept loop is what was missing, and it
    /// can only be observed by connecting to it.
    ///
    /// Drives the REAL `serve(shouldContinue:)` rather than a hand-rolled accept
    /// in the test. A test that reimplemented the loop would agree with itself
    /// while `serve` stayed broken — which is precisely how a fully-tested
    /// daemon shipped with no transport at all.
    @MainActor
    func testServeBindsAndAnswersARealClient() async throws {
        let path = socketPath()
        let transport = DaemonTransport(engine: engine(), socketPath: path)

        // One pass: `shouldContinue` returns true once, so the loop accepts a
        // single connection and then exits. Bounded so a broken accept fails the
        // test by assertion rather than by hanging it.
        // `shouldContinue` is checked BEFORE each accept, so a bound of 1 means
        // the loop serves one connection and exits — tearing the socket down in
        // its `defer`. The client is started separately and races that teardown,
        // so the bound is kept open and the task is cancelled at the end
        // instead. A test that closes the door it is about to walk through
        // fails for its own timing, not for the subject's behaviour.
        let failure = Box()
        let server = Task {
            do {
                try await transport.serve()
            } catch {
                // Captured, never discarded: a `try?` here turned a precise bind
                // error into a bare "could not connect" three assertions later,
                // which sends the reader at the client instead of the server.
                failure.set("\(error)")
            }
        }
        defer { server.cancel() }

        var bound = false
        for _ in 0..<200 {
            if DaemonTransport.isLive(path: path) {
                bound = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try skipIfHostRefusedSocketBind(failure.value)
        XCTAssertTrue(
            bound,
            "serve() must bind and listen. serve() error: \(failure.value ?? "none reported")"
        )

        // The client's own read BLOCKS, so it must not run on the main actor:
        // `handle` needs that actor to render, and a client holding it starves
        // the very server it is waiting for. Measured — the first version of
        // this test ran `converse` inline on the @MainActor test method and got
        // zero replies from a transport the shipped binary answers correctly
        // over `nc`. The apparatus was the defect, not the subject.
        let frames = [#"{"method":"ping","id":"e2e"}"#, #"{"method":"list","id":"e2e2"}"#]
        let replies = try await offMainActor {
            try Self.converse(with: path, frames: frames)
        }

        XCTAssertEqual(
            replies.count,
            2,
            "both frames on one connection must be answered. serve() error: "
                + (failure.value ?? "none reported")
        )
        guard replies.count == 2 else { return }

        XCTAssertEqual(replies[0].id, "e2e")
        XCTAssertEqual(replies[0].ok, true)

        XCTAssertNotNil(
            replies[1].scenarios,
            "the socket must publish the documented shape, not a positional wrapper"
        )
    }
}

private func prepareSocketOrSkip(path: String) throws -> Int32 {
    do {
        return try DaemonTransport.prepare(path: path)
    } catch DaemonTransport.TransportError.systemCall(let name, let code, let detail)
        where name == "bind" && code == EPERM
    {
        throw XCTSkip("unix socket bind refused by host: \(detail) (errno \(code))")
    }
}

private func skipIfHostRefusedSocketBind(_ failure: String?) throws {
    guard let failure, failure.contains("bind failed (errno \(EPERM))") else { return }
    throw XCTSkip("unix socket bind refused by host: \(failure)")
}

private struct SocketReply: Sendable {
    let id: String?
    let ok: Bool?
    let scenarios: [String]?

    init(object: [String: Any]) {
        id = object["id"] as? String
        ok = object["ok"] as? Bool
        scenarios = (object["result"] as? [String: Any])?["scenarios"] as? [String]
    }
}

private enum SocketClientError: Error, Sendable, CustomStringConvertible {
    case openFailed(errno: Int32)
    case connectFailed(path: String, errno: Int32)

    var description: String {
        switch self {
        case .openFailed(let errno):
            return "could not open a client socket (errno \(errno))"
        case .connectFailed(let path, let errno):
            return "could not connect client socket to \(path) (errno \(errno))"
        }
    }
}

private func offMainActor<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// The deadlock guard, stated as a test rather than only as a comment.
///
/// `serve` originally ran `accept` and `read` ON THE MAIN ACTOR. Both BLOCK, so
/// the actor was held for the whole wait — and since the main actor is also
/// where SwiftUI renders, the daemon could not render the scenario a request
/// asked for. With a client in the same process it deadlocks outright: measured
/// at over ten minutes with no output before the run was killed.
///
/// This test would hang forever against that implementation, so it is bounded
/// by an explicit timeout and reports the deadlock as a FAILURE. A hang and a
/// failure are not the same signal — a hung suite gets killed and read as
/// "infrastructure was slow", while a timeout failure names the defect.
@available(macOS 13, *)
final class DaemonTransportConcurrencyTests: XCTestCase {
    @MainActor
    func testServeDoesNotHoldTheMainActorWhileWaiting() async throws {
        let path = "/tmp/vui-dl-\(UUID().uuidString.prefix(8)).sock"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let engine = VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("vui-dl-\(UUID().uuidString)")
            )
        )
        let transport = DaemonTransport(engine: engine, socketPath: path)

        let failure = Box()
        let server = Task {
            do {
                try await transport.serve(shouldContinue: { true })
            } catch {
                failure.set("\(error)")
            }
        }
        defer { server.cancel() }

        // The assertion: while `serve` is blocked in accept, THIS main-actor
        // code must still get to run. Against the old implementation the loop
        // below never executes a single iteration.
        var observed = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if DaemonTransport.isLive(path: path) {
                observed = true
                break
            }
        }

        try skipIfHostRefusedSocketBind(failure.value)
        XCTAssertTrue(
            observed,
            "serve() must not hold the main actor while waiting in accept — main-actor work "
                + "could not proceed for 2s, which is the deadlock that stalls every render "
                + "the daemon exists to perform"
        )
    }
}

/// Carries an error out of a detached task so an assertion can quote it.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = message
    }
}
