import XCTest

@testable import VerdictUIWeb

private actor FakeCDPSocket: CDPSocket {
    struct Request: Decodable, Sendable {
        let id: Int
        let method: String
        let params: [String: CDPValue]
    }

    enum WriteMode: Sendable { case normal, suspended, failing }
    enum Failure: Error { case disconnected, writeFailed, observationTimedOut }

    private let writeMode: WriteMode
    private var frames: [String] = []
    private var replies: [Result<String, Failure>] = []
    private var reader: CheckedContinuation<String, any Error>?
    private var writers: [CheckedContinuation<Void, any Error>] = []
    private var closed = false

    init(writeMode: WriteMode = .normal) { self.writeMode = writeMode }

    func send(text: String) async throws {
        guard !closed else { throw Failure.disconnected }
        frames.append(text)
        switch writeMode {
        case .normal: return
        case .failing: throw Failure.writeFailed
        case .suspended:
            // Deliberately ignores Task cancellation. The transport's deadline
            // must still resume the caller without waiting for this write.
            try await withCheckedThrowingContinuation { writers.append($0) }
        }
    }

    func receive() async throws -> String {
        guard !closed else { throw Failure.disconnected }
        if !replies.isEmpty { return try replies.removeFirst().get() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func deliver(_ text: String) { deliver(.success(text)) }

    func disconnect() { deliver(.failure(.disconnected)) }

    private func deliver(_ reply: Result<String, Failure>) {
        if let reader {
            self.reader = nil
            switch reply {
            case let .success(text): reader.resume(returning: text)
            case let .failure(error): reader.resume(throwing: error)
            }
        } else {
            replies.append(reply)
        }
    }

    func close() {
        closed = true
        reader?.resume(throwing: Failure.disconnected)
        reader = nil
        for writer in writers { writer.resume(throwing: Failure.disconnected) }
        writers.removeAll()
    }

    func sentCount() -> Int { frames.count }

    func requests(count: Int) async throws -> [Request] {
        let deadline = ContinuousClock.now + .seconds(2)
        while frames.count < count {
            guard ContinuousClock.now < deadline else { throw Failure.observationTimedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        return try frames.map { try JSONDecoder().decode(Request.self, from: Data($0.utf8)) }
    }
}

@MainActor
final class CDPTransportTests: XCTestCase {
    private func fixture(
        writeMode: FakeCDPSocket.WriteMode = .normal
    ) -> (FakeCDPSocket, CDPTransport) {
        let socket = FakeCDPSocket(writeMode: writeMode)
        let transport = CDPTransport(socket: socket)
        addTeardownBlock { await transport.close() }
        return (socket, transport)
    }

    private func failure(
        _ request: Task<[String: CDPValue], any Error>,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> WebBrowserError? {
        do {
            _ = try await request.value
            XCTFail("request unexpectedly succeeded", file: file, line: line)
            return nil
        } catch {
            XCTAssertTrue(error is WebBrowserError, "untyped error: \(error)", file: file, line: line)
            return error as? WebBrowserError
        }
    }

    func testOutOfOrderRepliesMatchRequestIDs() async throws {
        let (socket, transport) = fixture()
        var tasks: [Task<[String: CDPValue], any Error>] = []
        for index in 0..<6 {
            tasks.append(Task {
                try await transport.send(
                    method: "Test.request\(index)",
                    params: ["index": .integer(Int64(index))], timeout: .seconds(3))
            })
            _ = try await socket.requests(count: index + 1)
        }
        let requests = try await socket.requests(count: 6)
        XCTAssertEqual(Set(requests.map(\.id)).count, 6)
        for (index, request) in requests.enumerated().reversed() {
            XCTAssertEqual(request.method, "Test.request\(index)")
            XCTAssertEqual(request.params, ["index": .integer(Int64(index))])
            await socket.deliver("{\"id\":\(request.id),\"result\":{\"index\":\(index)}}")
        }
        for (index, task) in tasks.enumerated() {
            let result = try await task.value
            XCTAssertEqual(result, ["index": .integer(Int64(index))])
        }
    }

    func testNoReplyTimesOutAndLateReplyDoesNotCompleteAnotherRequest() async throws {
        let (socket, transport) = fixture()
        let expired = Task {
            try await transport.send(method: "Test.expired", timeout: .milliseconds(100))
        }
        let old = try await socket.requests(count: 1)[0]
        let start = ContinuousClock.now
        let error = await failure(expired)
        XCTAssertEqual(error, .cdpRequestTimedOut(method: "Test.expired"))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))

        let current = Task { try await transport.send(method: "Test.current", timeout: .seconds(2)) }
        let newest = try await socket.requests(count: 2)[1]
        await socket.deliver("{\"id\":\(old.id),\"result\":{\"stale\":true}}")
        await socket.deliver("{\"id\":\(newest.id),\"result\":{\"current\":true}}")
        let result = try await current.value
        XCTAssertEqual(result, ["current": .bool(true)])
    }

    func testTimeoutIncludesASocketWriteThatIgnoresCancellation() async throws {
        let (socket, transport) = fixture(writeMode: .suspended)
        let start = ContinuousClock.now
        let request = Task {
            try await transport.send(method: "Test.blockedWrite", timeout: .milliseconds(100))
        }
        _ = try await socket.requests(count: 1)
        let error = await failure(request)
        XCTAssertEqual(error, .cdpRequestTimedOut(method: "Test.blockedWrite"))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testReceiveErrorFailsEveryInflightRequestAndLaterSends() async throws {
        let (socket, transport) = fixture()
        let first = Task { try await transport.send(method: "Test.first", timeout: .seconds(5)) }
        _ = try await socket.requests(count: 1)
        let second = Task { try await transport.send(method: "Test.second", timeout: .seconds(5)) }
        _ = try await socket.requests(count: 2)
        let start = ContinuousClock.now
        await socket.disconnect()
        let firstError = await failure(first)
        let secondError = await failure(second)
        guard case .cdpConnectionClosed = firstError else { return XCTFail("wrong error: \(String(describing: firstError))") }
        XCTAssertEqual(firstError, secondError)
        let laterError = await failure(Task { try await transport.send(method: "Test.later") })
        XCTAssertEqual(laterError, firstError)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let count = await socket.sentCount()
        XCTAssertEqual(count, 2)
    }

    func testExplicitCloseFailsInflightAndSendAfterCloseWithoutWriting() async throws {
        let (socket, transport) = fixture(writeMode: .suspended)
        let request = Task { try await transport.send(method: "Test.pending", timeout: .seconds(5)) }
        _ = try await socket.requests(count: 1)
        await transport.close()
        await transport.close()
        let expected = WebBrowserError.cdpConnectionClosed(reason: "closed by caller")
        let pendingError = await failure(request)
        XCTAssertEqual(pendingError, expected)
        let laterError = await failure(Task { try await transport.send(method: "Test.later") })
        XCTAssertEqual(laterError, expected)
        let count = await socket.sentCount()
        XCTAssertEqual(count, 1)
    }

    func testSendFailureIsTerminal() async throws {
        let (socket, transport) = fixture(writeMode: .failing)
        let error = await failure(Task { try await transport.send(method: "Test.write") })
        guard case .cdpConnectionClosed = error else { return XCTFail("wrong error: \(String(describing: error))") }
        let later = await failure(Task { try await transport.send(method: "Test.later") })
        XCTAssertEqual(later, error)
        let count = await socket.sentCount()
        XCTAssertEqual(count, 1)
    }

    func testCDPErrorCarriesCodeAndMessageWithoutClosingConnection() async throws {
        let (socket, transport) = fixture()
        let failed = Task { try await transport.send(method: "Missing.method") }
        let first = try await socket.requests(count: 1)[0]
        await socket.deliver("{\"id\":\(first.id),\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}")
        let error = await failure(failed)
        XCTAssertEqual(error, .cdpError(code: -32601, message: "Method not found"))
        let next = Task { try await transport.send(method: "Browser.getVersion") }
        let second = try await socket.requests(count: 2)[1]
        await socket.deliver("{\"id\":\(second.id),\"result\":{}}")
        let result = try await next.value
        XCTAssertEqual(result, [:])
    }

    func testEventsAndDuplicateRepliesAreIgnored() async throws {
        let (socket, transport) = fixture()
        let first = Task { try await transport.send(method: "Test.first") }
        let request = try await socket.requests(count: 1)[0]
        await socket.deliver("{\"method\":\"Target.targetCreated\",\"params\":{\"targetInfo\":{}}}")
        let reply = "{\"id\":\(request.id),\"result\":{\"done\":true}}"
        await socket.deliver(reply)
        let result = try await first.value
        XCTAssertEqual(result, ["done": .bool(true)])
        let second = Task { try await transport.send(method: "Test.second") }
        let next = try await socket.requests(count: 2)[1]
        await socket.deliver(reply)
        await socket.deliver("{\"id\":\(next.id),\"result\":{}}")
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, [:])
    }

    func testMalformedReplyFailsClosed() async throws {
        for frame in ["not JSON", "{}", "{\"id\":1}", "{\"id\":1,\"result\":{},\"error\":{\"code\":1,\"message\":\"ambiguous\"}}"] {
            let (socket, transport) = fixture()
            let request = Task { try await transport.send(method: "Test.invalid") }
            _ = try await socket.requests(count: 1)
            await socket.deliver(frame)
            let error = await failure(request)
            guard case .invalidCDPResponse = error else { return XCTFail("wrong error: \(String(describing: error))") }
            let later = await failure(Task { try await transport.send(method: "Test.later") })
            XCTAssertEqual(later, error)
        }
    }

    func testCancellationRemovesOnlyItsRequest() async throws {
        let (socket, transport) = fixture()
        let cancelled = Task { try await transport.send(method: "Test.cancel") }
        _ = try await socket.requests(count: 1)
        let survivor = Task { try await transport.send(method: "Test.survivor") }
        let request = try await socket.requests(count: 2)[1]
        cancelled.cancel()
        let error = await failure(cancelled)
        XCTAssertEqual(error, .cdpRequestCancelled(method: "Test.cancel"))
        await socket.deliver("{\"id\":\(request.id),\"result\":{}}")
        let result = try await survivor.value
        XCTAssertEqual(result, [:])
    }

    func testInvalidRequestDoesNotWriteAndJSONRoundTrips() async throws {
        let (socket, transport) = fixture()
        for duration in [Duration.zero, .seconds(-1)] {
            let error = await failure(Task { try await transport.send(method: "Test.bad", timeout: duration) })
            guard case .invalidCDPRequest = error else { return XCTFail("wrong error") }
        }
        let error = await failure(Task {
            try await transport.send(method: "Test.bad", params: ["number": .number(.nan)])
        })
        guard case .invalidCDPRequest = error else { return XCTFail("wrong error") }
        let count = await socket.sentCount()
        XCTAssertEqual(count, 0)
        let value = CDPValue.object([
            "array": .array([.null, .bool(true), .integer(Int64.max), .number(1.5), .string("text")])
        ])
        XCTAssertEqual(try JSONDecoder().decode(CDPValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testInvalidEndpointIsTyped() {
        XCTAssertThrowsError(try CDPTransport(endpoint: DevtoolsEndpoint(port: 0, browserPath: ""))) {
            guard case WebBrowserError.invalidCDPRequest = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
}
