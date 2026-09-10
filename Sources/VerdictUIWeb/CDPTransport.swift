import Foundation

/// JSON that can cross actor boundaries without `[String: Any]` or unchecked
/// sendability. Integer values preserve CDP node identifiers exactly.
public enum CDPValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([CDPValue])
    case object([String: CDPValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int64.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([CDPValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: CDPValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(decoded): try value.encode(decoded)
        case let .integer(decoded): try value.encode(decoded)
        case let .number(decoded): try value.encode(decoded)
        case let .string(decoded): try value.encode(decoded)
        case let .array(decoded): try value.encode(decoded)
        case let .object(decoded): try value.encode(decoded)
        }
    }
}

/// One connected text-frame socket. `close` must unblock outstanding I/O.
/// Tests inject an actor implementing this same boundary.
public protocol CDPSocket: Sendable {
    func send(text: String) async throws
    func receive() async throws -> String
    func close() async
}

private actor URLSessionCDPSocket: CDPSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        task = session.webSocketTask(with: url)
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case .data:
            throw WebBrowserError.invalidCDPResponse(reason: "expected a text frame")
        @unknown default:
            throw WebBrowserError.invalidCDPResponse(reason: "unknown WebSocket frame")
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    deinit {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Browser-scoped CDP requests, correlated by id and bounded from send to reply.
/// CDP events (envelopes with a method and no id) are deliberately ignored.
/// Call `close()` when the owning browser session ends.
public actor CDPTransport {
    private struct Request: Encodable {
        let id: Int
        let method: String
        let params: [String: CDPValue]
    }

    private struct Response: Decodable {
        struct Failure: Decodable {
            let code: Int
            let message: String
        }
        let id: Int?
        let method: String?
        let result: [String: CDPValue]?
        let error: Failure?
    }

    private struct Pending {
        let continuation: CheckedContinuation<[String: CDPValue], any Error>
        let deadline: ContinuousClock.Instant
        let method: String
        let timeoutTask: Task<Void, Never>
        let sendTask: Task<Void, Never>
    }

    private let socket: any CDPSocket
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var receiveTask: Task<Void, Never>?
    private var terminalError: WebBrowserError?

    public init(socket: any CDPSocket) {
        self.socket = socket
    }

    /// Uses the browser endpoint discovered by T1; no HTTP rediscovery needed.
    public init(endpoint: DevtoolsEndpoint) throws {
        guard (1...65535).contains(endpoint.port),
            endpoint.browserPath.hasPrefix("/devtools/browser/"),
            let url = URL(string: endpoint.websocketURL)
        else {
            throw WebBrowserError.invalidCDPRequest(reason: "invalid browser WebSocket endpoint")
        }
        socket = URLSessionCDPSocket(url: url)
    }

    /// The timeout covers BOTH sending the text frame and receiving its reply.
    /// A timed-out/cancelled request is removed; late replies are ignored, and
    /// other requests retain their own deadlines. Socket failures are terminal.
    public func send(
        method: String,
        params: [String: CDPValue] = [:],
        timeout: Duration = .seconds(10)
    ) async throws -> [String: CDPValue] {
        if let terminalError { throw terminalError }
        guard timeout > .zero, !method.isEmpty, nextID < Int.max else {
            throw WebBrowserError.invalidCDPRequest(reason: "positive timeout and nonempty method required")
        }
        if Task.isCancelled { throw WebBrowserError.cdpRequestCancelled(method: method) }
        let deadline = ContinuousClock.now + timeout
        let id = nextID
        nextID += 1
        let text: String
        do {
            text = String(decoding: try JSONEncoder().encode(
                Request(id: id, method: method, params: params)), as: UTF8.self)
        } catch {
            // Do not include parameter contents: later callers may send credentials.
            throw WebBrowserError.invalidCDPRequest(reason: "parameters are not valid JSON")
        }
        startReceivingIfNeeded()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) }
                    catch { return }
                    await self?.finish(id: id, result: .failure(
                        WebBrowserError.cdpRequestTimedOut(method: method)))
                }
                // An unstructured task is intentional: a task-group race waits
                // for its losing child, which hangs if a socket write ignores
                // cancellation. The continuation is owned only by this actor.
                let sendTask = Task { [weak self, socket] in
                    guard !Task.isCancelled else { return }
                    do { try await socket.send(text: text) }
                    catch {
                        await self?.sendFailed(id: id, error: Self.socketError(error))
                    }
                }
                pending[id] = Pending(
                    continuation: continuation, deadline: deadline, method: method,
                    timeoutTask: timeoutTask, sendTask: sendTask)
            }
        } onCancel: {
            Task { await self.finish(id: id, result: .failure(
                WebBrowserError.cdpRequestCancelled(method: method))) }
        }
    }

    /// Idempotent. Pending requests resume before any asynchronous socket cleanup.
    public func close() async {
        fail(.cdpConnectionClosed(reason: "closed by caller"))
        await socket.close()
    }

    private func startReceivingIfNeeded() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let text = try await socket.receive()
                    guard let self else { return }
                    await self.received(text)
                } catch {
                    await self?.fail(Self.socketError(error))
                    return
                }
            }
        }
    }

    private static func socketError(_ error: any Error) -> WebBrowserError {
        if let typed = error as? WebBrowserError { return typed }
        let nsError = error as NSError
        // Domain/code identify the failure without echoing a frame or credentials.
        return .cdpConnectionClosed(reason: "\(nsError.domain) (\(nsError.code))")
    }

    private func sendFailed(id: Int, error: WebBrowserError) {
        guard pending[id] != nil else { return }
        fail(error)
    }

    private func received(_ text: String) {
        guard terminalError == nil else { return }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: Data(text.utf8)) }
        catch {
            fail(.invalidCDPResponse(reason: "malformed CDP envelope"))
            return
        }
        guard let id = response.id else {
            if response.method == nil {
                fail(.invalidCDPResponse(reason: "envelope has neither id nor event method"))
            }
            return
        }
        guard (response.result != nil) != (response.error != nil) else {
            fail(.invalidCDPResponse(reason: "reply must contain exactly one result or error"))
            return
        }
        guard let request = pending[id] else { return } // Late/duplicate replies.
        if ContinuousClock.now >= request.deadline {
            finish(id: id, result: .failure(WebBrowserError.cdpRequestTimedOut(method: request.method)))
        } else if let error = response.error {
            finish(id: id, result: .failure(WebBrowserError.cdpError(code: error.code, message: error.message)))
        } else if let result = response.result {
            finish(id: id, result: .success(result))
        }
    }

    private func finish(id: Int, result: Result<[String: CDPValue], any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.sendTask.cancel()
        request.continuation.resume(with: result)
    }

    private func fail(_ error: WebBrowserError) {
        guard terminalError == nil else { return }
        terminalError = error
        receiveTask?.cancel()
        receiveTask = nil
        for id in Array(pending.keys) { finish(id: id, result: .failure(error)) }
        Task { [socket] in await socket.close() }
    }

    deinit {
        receiveTask?.cancel()
        // The receive task keeps only a weak transport reference, so forgetting
        // close cannot keep the session alive indefinitely while waiting for I/O.
        Task { [socket] in await socket.close() }
    }
}
