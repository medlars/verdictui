// Wave 7: the stdio transport the MCP server was missing.
//
// `MCPServer` has held the tool catalog and the tool→method table since Wave 7's
// core landed, and both were tested — but nothing read stdin, so no MCP client
// could reach any of it. `contracts/mcp-tools.md` described a live wire protocol
// in the present tense against a server that never started (`no.md` #34).
//
// Like `DaemonTransport`, this file frames bytes and nothing more. Every tool
// dispatches through `MCPServer.daemonMethod(for:)` into `VerdictDaemon.handle`
// — the same method surface the CLI and the socket use. A switch here that
// answered `verify` itself is how three surfaces drift into three answers.
import Foundation
import VerdictUIKernel

/// Serves the MCP tool catalog over newline-delimited JSON-RPC on stdin/stdout.
@available(macOS 13, *)
public struct MCPTransport: Sendable {
    private let engine: VerdictEngine

    public init(engine: VerdictEngine) {
        self.engine = engine
    }

    /// The MCP protocol revision this server implements.
    public static let protocolVersion = "2024-11-05"

    // MARK: - The loop

    /// Read requests from `input` and write replies to `output` until EOF.
    ///
    /// Both handles are parameters rather than hardcoded `FileHandle.standard*`
    /// so a test can drive the real loop over pipes. A transport whose only
    /// possible input is the process's own stdin can be tested only by spawning
    /// a process, and then the loop itself — the part with the framing bugs —
    /// gets covered incidentally or not at all.
    ///
    /// Deliberately NOT `@MainActor`, for the reason `DaemonTransport.serve`
    /// documents at length: `availableData` BLOCKS, the main actor is where
    /// rendering happens, and a blocking read held there stalls the render each
    /// request needs. Only `handle` hops onto the main actor.
    public func serve(input: FileHandle, output: FileHandle) async {
        var pending = Data()

        while true {
            let chunk = await Self.readOffActor(input)
            if chunk.isEmpty {
                // EOF. A trailing partial frame is a truncated request; it is
                // not answered, because the bytes that would say what it asked
                // never arrived.
                return
            }
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                guard !line.isEmpty else { continue }
                guard let reply = await answer(Data(line)) else { continue }
                output.write(reply)
            }
        }
    }

    /// Block in `availableData` on a background thread.
    private static func readOffActor(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handle.availableData)
            }
        }
    }

    // MARK: - One message

    /// Answer one JSON-RPC line, or return nil when none is owed.
    ///
    /// A NOTIFICATION — a JSON-RPC message with no `id` — must not be answered.
    /// The distinction is load-bearing rather than pedantic: MCP clients send
    /// `notifications/initialized` during handshake, and a server that replies
    /// to it puts an unexpected message on the wire that strict clients treat as
    /// a protocol error, which presents as "the server never finished starting".
    @MainActor
    func answer(_ line: Data) async -> Data? {
        let message: MCPRequest
        do {
            message = try JSONDecoder().decode(MCPRequest.self, from: line)
        } catch {
            return Self.encode(
                MCPResponse(
                    id: nil,
                    result: nil,
                    error: MCPError(code: -32700, message: "parse error: \(error)")
                )
            )
        }

        guard let id = message.id else { return nil }

        switch message.method {
        case "initialize":
            return Self.encode(
                MCPResponse(
                    id: id,
                    result: .initialize(
                        MCPInitializeResult(
                            protocolVersion: Self.protocolVersion,
                            serverInfo: MCPServerInfo(
                                name: "verdictui",
                                version: SchemaVersion.current
                            )
                        )
                    ),
                    error: nil
                )
            )

        case "tools/list":
            return Self.encode(
                MCPResponse(id: id, result: .tools(MCPToolList(tools: MCPServer.tools)), error: nil)
            )

        case "tools/call":
            return await callTool(message, id: id)

        case "ping":
            return Self.encode(MCPResponse(id: id, result: .empty(MCPEmpty()), error: nil))

        default:
            return Self.encode(
                MCPResponse(
                    id: id,
                    result: nil,
                    error: MCPError(
                        code: -32601,
                        message: "unknown method '\(message.method)'"
                    )
                )
            )
        }
    }

    /// Run one tool call through the daemon's method surface.
    ///
    /// ### Why a failing verdict is not an error
    ///
    /// `isError` reports whether the tool COULD ANSWER, never what the answer
    /// was. A scenario whose layout is broken returns `isError: false` carrying
    /// a FAILING verdict — the tool did its job. Only an unrenderable scenario
    /// or an unknown tool sets `isError`. An agent that conflated the two would
    /// retry a real defect as though it were a transport fault, and would report
    /// an infrastructure outage as a UI bug.
    @MainActor
    private func callTool(_ message: MCPRequest, id: MCPID) async -> Data {
        guard let parameters = message.params else {
            return Self.toolFailure(id: id, message: "tools/call requires params")
        }
        guard let method = MCPServer.daemonMethod(for: parameters.name) else {
            return Self.toolFailure(id: id, message: "unknown tool '\(parameters.name)'")
        }

        let arguments = parameters.arguments ?? [:]
        // An `act` needs a verb and a probe, and a client that omits either is
        // refused HERE rather than by building a half-formed DaemonAction: an
        // action defaulting its probe to "" reaches the harness as a real
        // request against a probe that cannot exist, which comes back as
        // "no action binding registered for probe id ''" — a true sentence that
        // sends the reader looking at the scenario instead of at their call.
        var action: DaemonAction?
        if method == "act" {
            guard let kind = arguments["action"]?.stringValue else {
                return Self.toolFailure(id: id, message: "act requires an 'action' argument")
            }
            guard let probe = arguments["probe"]?.stringValue else {
                return Self.toolFailure(id: id, message: "act requires a 'probe' argument")
            }
            action = DaemonAction(
                kind: kind,
                probe: probe,
                text: arguments["text"]?.stringValue,
                value: arguments["value"]?.numberValue
            )
        }

        let request = DaemonRequest(
            method: method,
            scenario: arguments["scenario"]?.stringValue,
            baseline: arguments["baseline"]?.boolValue,
            action: action,
            includeTree: arguments["include_tree"]?.boolValue,
            crossValidate: arguments["cross_validate"]?.boolValue,
            id: nil
        )
        let response = await VerdictDaemon.handle(request, engine: engine)

        guard response.ok, let result = response.result else {
            return Self.toolFailure(
                id: id,
                message: response.error ?? "the tool produced no result"
            )
        }

        let text: String
        do {
            text = try Self.render(result)
        } catch {
            return Self.toolFailure(id: id, message: "could not encode result: \(error)")
        }
        return Self.encode(
            MCPResponse(
                id: id,
                result: .toolCall(
                    MCPToolResult(content: [MCPContent(text: text)], isError: false)
                ),
                error: nil
            )
        )
    }

    /// Render a daemon result as the JSON text an MCP client receives.
    ///
    /// Trees go over the wire in the COMPACT form: `CompactTree` exists because
    /// a full `SemanticNode` tree costs several times an agent's per-message
    /// budget, and the transport is where that saving has to be applied.
    static func render(_ result: DaemonResult) throws -> String {
        let encoder = VerdictOutput.encoder(pretty: false)
        let data: Data
        switch result {
        case .scenarios(let names): data = try encoder.encode(names)
        case .verdict(let verdict): data = try encoder.encode(verdict)
        case .tree(let tree): data = try encoder.encode(CompactTree(tree))
        // Already compact: `StepResultWire` carries a `CompactDelta` and an
        // optional `CompactTree`, so the saving is applied where the value is
        // BUILT rather than here. Doing it here instead would mean the socket
        // daemon shipped the raw form while MCP shipped the compact one — two
        // wires for one method.
        case .step(let step): data = try encoder.encode(step)
        case .sweep(let report): data = try encoder.encode(report)
        case .findings(let findings): data = try encoder.encode(findings)
        case .pong(let version): data = try encoder.encode(["schemaVersion": version])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool that could not answer, reported as a tool result rather than a
    /// protocol error.
    ///
    /// MCP draws this line deliberately: a JSON-RPC error means the CALL was
    /// malformed, while `isError: true` means the call was well-formed and the
    /// tool failed. Reporting an unknown scenario as a protocol error would tell
    /// the agent its own message was wrong, sending it to fix the wrong thing.
    private static func toolFailure(id: MCPID, message: String) -> Data {
        encode(
            MCPResponse(
                id: id,
                result: .toolCall(
                    MCPToolResult(content: [MCPContent(text: message)], isError: true)
                ),
                error: nil
            )
        )
    }

    /// Encode one response as a newline-terminated line.
    static func encode(_ response: MCPResponse) -> Data {
        guard var data = try? VerdictOutput.encoder(pretty: false).encode(response) else {
            return Data(#"{"jsonrpc":"2.0","error":{"code":-32603,"message":"encode failed"}}"#.utf8
                + [0x0A])
        }
        data.append(0x0A)
        return data
    }
}

// MARK: - Wire types

/// An incoming JSON-RPC message.
///
/// ### Why `params` decodes leniently
///
/// `params` is typed for `tools/call`, but it is a free-form JSON-RPC field that
/// every OTHER method fills with its own shape — `initialize` sends
/// `protocolVersion`/`capabilities`/`clientInfo` and no `name` at all. With the
/// synthesized decoder, a `params` block of any other shape failed to decode the
/// whole ENVELOPE, so the message never reached its handler: the server answered
/// the first message of every real client session with a parse error, while
/// `initialize` had a correct handler sitting unreachable behind it.
///
/// A `params` this type cannot read is therefore recorded as absent rather than
/// fatal. `callTool` is the only reader and already rejects a missing `params`
/// with a tool-level error, so a genuinely malformed `tools/call` still fails —
/// it just fails as that call rather than as the connection.
public struct MCPRequest: Codable, Sendable {
    public let jsonrpc: String?
    public let id: MCPID?
    public let method: String
    public let params: MCPCallParams?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(MCPID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try? container.decodeIfPresent(MCPCallParams.self, forKey: .params)
    }
}

/// `tools/call` parameters.
public struct MCPCallParams: Codable, Sendable {
    public let name: String
    public let arguments: [String: MCPValue]?
}

/// A JSON-RPC id, which the spec allows to be a string or a number.
///
/// Modelled as an enum rather than normalized to a string because the id must be
/// echoed back in the SHAPE it arrived in — a client that sent `3` and receives
/// `"3"` cannot match the reply to its request.
public enum MCPID: Codable, Sendable, Equatable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

/// A tool argument value, decoded loosely because MCP arguments are free-form.
public enum MCPValue: Codable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case other

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped number, or `nil`.
    ///
    /// Deliberately does NOT fall back to parsing a `.string`: a client sending
    /// `"0.5"` for a slider has sent the wrong type, and quietly accepting it
    /// would make the schema a suggestion. The refusal names the argument.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool BEFORE number: JSONDecoder will happily decode `true` as 1.0,
        // and a `baseline` argument silently becoming a number is a flag that
        // stops working with no error anywhere.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .other
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .other: try container.encodeNil()
        }
    }
}

/// An outgoing JSON-RPC response.
public struct MCPResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: MCPID?
    public let result: MCPResult?
    public let error: MCPError?

    public init(id: MCPID?, result: MCPResult?, error: MCPError?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

/// The result shapes this server returns.
public enum MCPResult: Codable, Sendable {
    case initialize(MCPInitializeResult)
    case tools(MCPToolList)
    case toolCall(MCPToolResult)
    case empty(MCPEmpty)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .initialize(let value): try container.encode(value)
        case .tools(let value): try container.encode(value)
        case .toolCall(let value): try container.encode(value)
        case .empty(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(MCPToolList.self), !value.tools.isEmpty {
            self = .tools(value)
        } else if let value = try? container.decode(MCPToolResult.self) {
            self = .toolCall(value)
        } else if let value = try? container.decode(MCPInitializeResult.self) {
            self = .initialize(value)
        } else {
            self = .empty(try container.decode(MCPEmpty.self))
        }
    }
}

/// What `initialize` reports back.
public struct MCPInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: MCPCapabilities
    public let serverInfo: MCPServerInfo

    public init(protocolVersion: String, serverInfo: MCPServerInfo) {
        self.protocolVersion = protocolVersion
        self.capabilities = MCPCapabilities()
        self.serverInfo = serverInfo
    }
}

/// This server offers tools and nothing else — no resources, no prompts.
public struct MCPCapabilities: Codable, Sendable {
    public let tools: MCPEmpty

    public init() {
        self.tools = MCPEmpty()
    }
}

/// Server identity.
public struct MCPServerInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// The `tools/list` payload.
public struct MCPToolList: Codable, Sendable {
    public let tools: [MCPTool]

    public init(tools: [MCPTool]) {
        self.tools = tools
    }
}

/// The `tools/call` payload.
public struct MCPToolResult: Codable, Sendable {
    public let content: [MCPContent]
    /// Whether the tool COULD NOT ANSWER — never whether the verdict passed.
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool) {
        self.content = content
        self.isError = isError
    }
}

/// One content block.
public struct MCPContent: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "text"
        self.text = text
    }
}

/// A JSON-RPC error object.
public struct MCPError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

/// An empty JSON object, which MCP uses in several places.
public struct MCPEmpty: Codable, Sendable {
    public init() {}
}
