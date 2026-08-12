import Foundation
import VerdictUIDemoScenarios
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// SLO 3 — warm MCP round-trip latency, measured through the REAL stdio
/// transport of the BUILT binary.
///
/// ### Why this cannot be an in-process measurement
///
/// SLO 1 times `Harness.perform` inside the test process. That is the engine's
/// number and it is the right number for the engine — but an agent does not
/// call `perform`; it writes a JSON frame to a pipe and waits for one back. The
/// difference is process boundary, framing, JSON encode/decode, and pipe
/// scheduling, and none of it appears in an in-process timing. A tool that is
/// fast in-process and slow on the wire is slow, and only this measurement can
/// say so.
///
/// It is the same principle as `CLIBinarySmokeTests`: a suite verifies code and
/// cannot see the artifact that ships (`no.md` #32). Here the artifact's
/// LATENCY is the subject.
///
/// ### Which statistic is gated, and why it is the median
///
/// The same lane rule SLO 1 arrived at the hard way (`no.md` #13, #15), reached
/// independently here by measurement rather than inherited by analogy.
///
/// Measured 2026-08-12 on the release binary, 60 samples after 5 warm-up calls,
/// three consecutive runs:
///
/// | | p50 | p95 |
/// |---|---|---|
/// | idle | 8.30 / 8.29 / 8.29 ms | 8.52 / 8.67 / 8.44 ms |
/// | under 8 spinning cores | 10.05 / 10.33 / 11.30 ms | 11.91 / 12.01 / **45.82** ms |
///
/// The median moves 8.3 → 11.3 ms under load — it degrades honestly and stays
/// bounded. The tail moves 8.4 → 45.8 ms, a 5x swing on unchanged code, because
/// one descheduled sample is enough to move it. A gate on p95 would fail for a
/// busy neighbour and teach its reader to discount it; a gate on p50 fails for
/// the code. So p50 is asserted and p95 is recorded, exactly as SLO 1 does.
///
/// The budget is 40 ms — roughly 4x the idle median and well above the loaded
/// one, so it fails on a regression rather than on a bad afternoon, while still
/// sitting far inside the plan's 100 ms product target.
@available(macOS 13, *)
final class MCPLatencyTests: XCTestCase {
    /// Samples per run, after the warm-up.
    private static let sampleCount = 60

    /// Calls discarded before sampling begins.
    ///
    /// "Warm" is the claim being measured, and the first call through a fresh
    /// process pays one-time costs — scenario registry construction, the first
    /// render's allocations — that no subsequent call pays. Sampling them would
    /// measure startup while calling it steady-state.
    private static let warmupCount = 5

    /// The GATED figure: warm median round trip, in milliseconds.
    private static let warmP50BudgetMs: Double = 40

    /// The published product target from `docs/slo.md`. Recorded, not asserted.
    private static let warmP95BudgetMs: Double = 100

    /// Whether this process can produce comparable timings at all.
    ///
    /// Delegates to the shared marker class rather than re-spelling it — three
    /// timing suites had already diverged once, and only one of them honoured
    /// `CI` (`no.md` #17). A constrained host records; it never asserts.
    private static var assertsP50Locally: Bool { !ConstrainedTimingEnvironment.isActive }

    /// The built product, or `nil` when it has not been built.
    ///
    /// `swift test` does not build executable products, so on a bare run this
    /// suite has no subject and says so. An absent binary is "could not
    /// observe", never "observed and fine" — the PM builds the product before
    /// the stages that drive it.
    private static var binaryURL: URL? {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Prefer release: it is what `.mcp.json` registers and what a user runs.
        return ["release", "debug"]
            .map { packageRoot.appendingPathComponent(".build/\($0)/verdictui") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// One long-lived `verdictui mcp` process, driven over its real pipes.
    private struct Client {
        let process: Process
        let toServer: FileHandle
        let fromServer: FileHandle
        private let reader: LineReader

        init(binary: URL) throws {
            let input = Pipe()
            let output = Pipe()
            process = Process()
            process.executableURL = binary
            process.arguments = ["mcp"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()

            toServer = input.fileHandleForWriting
            fromServer = output.fileHandleForReading
            reader = LineReader(handle: output.fileHandleForReading)
        }

        /// Send one frame and block until its reply line arrives.
        ///
        /// Timed by the CALLER, so the measurement covers exactly what an agent
        /// waits on: write, server work, read.
        func roundTrip(_ message: [String: Any]) throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: message)
            toServer.write(payload + Data([0x0A]))

            guard let line = reader.nextLine() else {
                throw MCPLatencyError.serverClosedTheConnection
            }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            else {
                throw MCPLatencyError.replyWasNotAJSONObject(String(decoding: line, as: UTF8.self))
            }
            return object
        }

        func shutDown() {
            try? toServer.close()
            process.waitUntilExit()
        }
    }

    private enum MCPLatencyError: Error {
        case serverClosedTheConnection
        case replyWasNotAJSONObject(String)
        case replyCarriedAnError(String)
    }

    /// Reads newline-delimited frames from a handle.
    ///
    /// A frame is not a read: one `availableData` can return half a frame or
    /// three of them, so a reader that equated the two would time the pipe's
    /// chunking rather than the server's work.
    private final class LineReader {
        private let handle: FileHandle
        private var buffer = Data()

        init(handle: FileHandle) {
            self.handle = handle
        }

        func nextLine() -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    if line.isEmpty { continue }
                    return Data(line)
                }
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
            }
        }
    }

    // MARK: - The measurement

    func testWarmVerifyRoundTripMeetsTheLatencyBudget() throws {
        guard let binary = Self.binaryURL else {
            throw XCTSkip("verdictui not built — nothing to measure (run swift build first)")
        }

        let client = try Client(binary: binary)
        defer { client.shutDown() }

        // The handshake carries params, as every real client's does. The
        // paramless spelling is the one that decodes even when the envelope is
        // broken, so using it here would measure a server no client can reach
        // (`no.md` #37).
        let handshake = try client.roundTrip([
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": [
                "protocolVersion": MCPTransport.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "verdictui-latency", "version": "1"],
            ],
        ])
        XCTAssertNotNil(
            handshake["result"],
            "the server did not complete a handshake, so every timing below would be an "
                + "error round trip: \(handshake)"
        )

        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "verify",
                "arguments": ["scenario": CleanSettingsScenario.scenarioName],
            ],
        ]

        for _ in 0..<Self.warmupCount {
            _ = try client.roundTrip(call)
        }

        var samples: [Double] = []
        samples.reserveCapacity(Self.sampleCount)
        for _ in 0..<Self.sampleCount {
            let start = ContinuousClock.now
            let reply = try client.roundTrip(call)
            let elapsed = ContinuousClock.now - start

            // A reply that is an ERROR is fast for the wrong reason. Without
            // this, a server that had stopped rendering entirely would post the
            // best numbers this suite has ever seen.
            guard let result = reply["result"] as? [String: Any] else {
                throw MCPLatencyError.replyCarriedAnError("\(reply)")
            }
            XCTAssertEqual(
                result["isError"] as? Bool,
                false,
                "a tool-level error is not a verify: \(result)"
            )

            samples.append(Double(elapsed.components.attoseconds) / 1_000_000_000_000_000)
        }

        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int(0.95 * Double(sorted.count)) - 1]

        // Printed in both lanes, so a regression is visible in the log even
        // where it is not fatal.
        print(
            String(
                format: "SLO3-MCP p50=%.2fms p95=%.2fms min=%.2fms max=%.2fms n=%d",
                p50, p95, sorted.first ?? 0, sorted.last ?? 0, sorted.count
            )
        )

        // Proof the benchmark RAN, asserted in every lane. A suite that silently
        // stopped measuring must never read as a fast one.
        XCTAssertEqual(samples.count, Self.sampleCount, "the sample count is the proof it ran")
        XCTAssertTrue(sorted.allSatisfy(\.isFinite), "a non-finite sample means a broken clock")
        XCTAssertGreaterThan(p50, 0, "a zero median means nothing was timed")

        guard Self.assertsP50Locally else {
            print(
                String(
                    format: "SLO3-MCP-P50 recorded p50=%.2fms on a constrained host "
                        + "(budget %.0fms — recorded, not asserted)",
                    p50, Self.warmP50BudgetMs
                )
            )
            return
        }

        XCTAssertLessThan(
            p50,
            Self.warmP50BudgetMs,
            "warm MCP round trip median \(p50) ms exceeds \(Self.warmP50BudgetMs) ms on "
                + "developer hardware, where the median is load-stable (measured 8.3 ms idle, "
                + "11.3 ms under 8 spinning cores). The tail is NOT gated — see the type doc."
        )
        print(
            String(
                format: "SLO3-MCP-P95 recorded p95=%.2fms (budget %.0fms — recorded, not asserted)",
                p95, Self.warmP95BudgetMs
            )
        )
    }

    /// The lane decision is read through its CONSEQUENCE, not its predicate.
    ///
    /// `XCTAssertFalse(ConstrainedTimingEnvironment.isActive)` would pass
    /// whichever way the flag branches, since inverting `assertsP50Locally`
    /// leaves the underlying property untouched — the shape that made an
    /// earlier guard unfalsifiable (`no.md` #12, #17).
    func testTheP50BudgetIsAssertedOnDeveloperHardware() throws {
        try XCTSkipIf(
            ConstrainedTimingEnvironment.isActive,
            "constrained host: recording is correct here"
        )
        XCTAssertTrue(
            Self.assertsP50Locally,
            "on developer hardware the median must be ASSERTED; a suite that records "
                + "everywhere enforces the budget nowhere and still reads green"
        )
    }

    /// The budget must stay a real gate, not a number nothing can breach.
    ///
    /// A budget raised until it stops failing is a silencer. This pins it
    /// against the measurement that justified it: 40 ms is ~4x the 8.3 ms idle
    /// median, so it has headroom for load without being unbreachable.
    func testTheBudgetIsWithinTheProductTarget() {
        XCTAssertLessThan(
            Self.warmP50BudgetMs,
            Self.warmP95BudgetMs,
            "the gated median budget must sit inside the published product target"
        )
        XCTAssertGreaterThan(
            Self.warmP50BudgetMs,
            12,
            "the budget must clear the loaded median (11.3 ms measured) or it fails for "
                + "contention rather than for regression"
        )
    }
}
