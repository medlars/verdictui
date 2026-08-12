// Wave 6: the warm daemon.
//
// A cold `verdictui verify` pays for process start, SwiftPM resolution and the
// first AppKit/SwiftUI warm-up before it renders anything. Measured on this
// machine: the first sweep cell costs ~209 ms against a ~120 ms steady state,
// and that is only the render — the process around it costs more. An agent
// calling verify in a loop pays all of it every time.
//
// The daemon keeps the process alive and answers JSON-RPC over a unix socket,
// so repeat verifies pay only the render.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// A JSON-RPC request the daemon understands.
public struct DaemonRequest: Codable, Sendable, Equatable {
    /// Method name: `list`, `render`, `verify`, `sweep`, `baseline_diff`, `ping`.
    public let method: String
    /// Scenario the method applies to, when it needs one.
    public let scenario: String?
    /// Whether `verify` should also compare against the baseline.
    public let baseline: Bool?
    /// Caller-supplied correlation id, echoed back untouched.
    public let id: String?

    public init(method: String, scenario: String? = nil, baseline: Bool? = nil, id: String? = nil) {
        self.method = method
        self.scenario = scenario
        self.baseline = baseline
        self.id = id
    }
}

/// A JSON-RPC response.
///
/// `ok` and `error` are separate rather than an error-shaped result, because
/// the distinction the CLI draws between "the UI is wrong" and "I could not
/// look" must survive the wire. A response carrying a FAILING verdict is
/// `ok: true` — the daemon did its job — while an unknown scenario is
/// `ok: false`, and a client that conflated them would report an infrastructure
/// fault as a product defect.
public struct DaemonResponse: Codable, Sendable {
    /// Whether the request was ANSWERED, not whether the verdict passed.
    public let ok: Bool
    /// The caller's correlation id, echoed.
    public let id: String?
    /// The result payload, when there is one.
    public let result: DaemonResult?
    /// Why the request could not be answered.
    public let error: String?

    public init(ok: Bool, id: String?, result: DaemonResult?, error: String?) {
        self.ok = ok
        self.id = id
        self.result = result
        self.error = error
    }
}

/// The payload shapes a daemon method can return.
///
/// An enum with explicit cases rather than a free-form dictionary: a client
/// decoding this knows every shape it may receive, and adding a method is a
/// compile error at every switch instead of a runtime surprise.
///
/// ### Why the coding is hand-written
///
/// Swift's SYNTHESIZED encoding for an enum with associated values wraps the
/// payload in a positional key, so `.scenarios([…])` shipped as
/// `{"scenarios":{"_0":[…]}}` while `contracts/mcp-tools.md` published
/// `{"scenarios":[…]}`. Nothing caught it for a wave: every test encoded and
/// decoded through this same `Codable`, so it agreed with itself no matter what
/// bytes travelled between. `_0` is also a compiler detail, not a promise — it
/// would have changed shape the moment a case gained a second value.
public enum DaemonResult: Codable, Sendable {
    case scenarios([String])
    case verdict(Verdict)
    case tree(SemanticNode)
    case sweep(SweepReportWire)
    case findings([Finding])
    case pong(String)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scenarios, verdict, tree, sweep, findings, pong
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scenarios(let value): try container.encode(value, forKey: .scenarios)
        case .verdict(let value): try container.encode(value, forKey: .verdict)
        case .tree(let value): try container.encode(value, forKey: .tree)
        case .sweep(let value): try container.encode(value, forKey: .sweep)
        case .findings(let value): try container.encode(value, forKey: .findings)
        case .pong(let value): try container.encode(value, forKey: .pong)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Ordered most- to least-specific is not enough on its own, because
        // each case has a distinct key: exactly one is present, so the first
        // match IS the answer. A payload with none of them is a malformed
        // result, reported as such rather than defaulted to an empty case.
        if let value = try container.decodeIfPresent([String].self, forKey: .scenarios) {
            self = .scenarios(value)
        } else if let value = try container.decodeIfPresent(Verdict.self, forKey: .verdict) {
            self = .verdict(value)
        } else if let value = try container.decodeIfPresent(SemanticNode.self, forKey: .tree) {
            self = .tree(value)
        } else if let value = try container.decodeIfPresent(SweepReportWire.self, forKey: .sweep) {
            self = .sweep(value)
        } else if let value = try container.decodeIfPresent([Finding].self, forKey: .findings) {
            self = .findings(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .pong) {
            self = .pong(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "a result carried none of the documented keys: "
                        + CodingKeys.allCases.map(\.rawValue).joined(separator: ", ")
                )
            )
        }
    }
}

/// Serves ``VerdictEngine`` over a unix-domain socket.
///
/// ### Why a unix socket and not a TCP port
///
/// A TCP listener is reachable by anything on the machine, and this daemon
/// renders arbitrary registered scenarios and WRITES BASELINES. A unix socket
/// inherits filesystem permissions, so the same user that could run the binary
/// is the only one that can drive it — the authorization question is answered
/// by the OS rather than by an auth layer this project would have to write and
/// get right.
///
/// ### What this daemon deliberately does NOT do
///
/// It does not accept a `baseline update`. Every other method is a read of the
/// UI; that one destroys the record of what the UI should be, and a
/// long-running socket-reachable process is the wrong place to put the single
/// destructive operation in the product. `verdictui baseline --update
/// --accept` remains a foreground command a human runs and watches.
public actor VerdictDaemon {
    private let engine: VerdictEngine
    private let socketPath: String

    /// Conventional socket location.
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".verdictui/daemon.sock")
            .path
    }

    public init(engine: VerdictEngine, socketPath: String = VerdictDaemon.defaultSocketPath) {
        self.engine = engine
        self.socketPath = socketPath
    }

    /// Answer one request.
    ///
    /// Separated from the socket plumbing so the whole method surface is
    /// testable without binding anything — a daemon whose behaviour can only be
    /// observed through a socket is a daemon whose behaviour is mostly
    /// untested.
    @MainActor
    public static func handle(
        _ request: DaemonRequest,
        engine: VerdictEngine
    ) async -> DaemonResponse {
        func failure(_ message: String) -> DaemonResponse {
            DaemonResponse(ok: false, id: request.id, result: nil, error: message)
        }
        func success(_ result: DaemonResult) -> DaemonResponse {
            DaemonResponse(ok: true, id: request.id, result: result, error: nil)
        }

        // Methods needing a scenario resolve it ONCE, here, so a missing
        // argument is reported as a missing argument rather than surfacing as
        // "no scenario named ''" from two layers down. Bound to a local rather
        // than force-unwrapped at each use: a guard several lines above a `!`
        // is a correctness argument a reader has to reconstruct, and a later
        // method added to the list without a matching `!` would crash the
        // daemon rather than answer.
        let needsScenario = ["render", "verify", "sweep", "baseline_diff"]
        guard let scenario = request.scenario else {
            if needsScenario.contains(request.method) {
                return failure("method '\(request.method)' requires a scenario")
            }
            // Methods that need no scenario continue below with a name they
            // will not read.
            return await handleScenarioFree(request, engine: engine)
        }

        do {
            switch request.method {
            case "ping", "list":
                return await handleScenarioFree(request, engine: engine)

            case "render":
                let tree = try await engine.render(scenario: scenario)
                return success(.tree(tree))

            case "verify":
                let verdict = try await engine.verify(
                    scenario: scenario,
                    againstBaseline: request.baseline ?? false
                )
                return success(.verdict(verdict))

            case "sweep":
                let report = try await engine.sweep(
                    scenario: scenario,
                    variants: [Variant.baseline]
                )
                return success(.sweep(SweepReportWire(report)))

            case "baseline_diff":
                let comparison = try await engine.baselineDiff(scenario: scenario)
                return success(.findings(comparison.findings))

            default:
                return failure("unknown method '\(request.method)'")
            }
        } catch let error as VerdictEngine.EngineError {
            return failure(error.description)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// The methods that read nothing but the engine itself.
    @MainActor
    private static func handleScenarioFree(
        _ request: DaemonRequest,
        engine: VerdictEngine
    ) async -> DaemonResponse {
        switch request.method {
        case "ping":
            return DaemonResponse(
                ok: true,
                id: request.id,
                result: .pong(SchemaVersion.current),
                error: nil
            )
        case "list":
            return DaemonResponse(
                ok: true,
                id: request.id,
                result: .scenarios(engine.scenarioNames),
                error: nil
            )
        default:
            return DaemonResponse(
                ok: false,
                id: request.id,
                result: nil,
                error: "unknown method '\(request.method)'"
            )
        }
    }

    /// Where this daemon listens.
    public nonisolated var socket: String { socketPath }

    /// Encode a response as one newline-terminated JSON document.
    ///
    /// Newline-delimited rather than length-prefixed: the wire is then
    /// inspectable with `nc` and a socket that desynchronizes fails visibly at
    /// the next parse instead of silently consuming the wrong byte count.
    public static func encode(_ response: DaemonResponse) throws -> Data {
        var data = try VerdictOutput.encoder(pretty: false).encode(response)
        data.append(0x0A)
        return data
    }

    /// Decode one request from a newline-delimited line.
    public static func decode(_ line: Data) throws -> DaemonRequest {
        try JSONDecoder().decode(DaemonRequest.self, from: line)
    }
}
