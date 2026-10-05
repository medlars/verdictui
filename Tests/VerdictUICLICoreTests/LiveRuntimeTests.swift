import ApplicationServices
import Foundation
import XCTest
import VerdictUIKernel
import VerdictUIWitness
@testable import VerdictUICLICore

final class LiveRuntimeTests: XCTestCase {
    private func tree(_ text: String) -> SemanticNode {
        SemanticNode(
            id: "status", role: .text,
            frame: Rect(x: 0, y: 0, width: 200, height: 40), text: text
        )
    }

    func testInvalidTargetsAndEmptyExpectationsAreRejected() {
        for request in [
            LiveRequest(pid: 0), LiveRequest(pid: -1),
            LiveRequest(pid: 1, timeout: .infinity), LiveRequest(pid: 1, timeout: 0),
            LiveRequest(pid: 1, expectText: ""), LiveRequest(pid: 1, surface: "all"),
        ] {
            XCTAssertThrowsError(try request.validatedTarget())
        }
        XCTAssertNoThrow(try LiveRequest(pid: 1).validatedTarget())
    }

    func testMCPRejectsLossyAndWrongTypeArguments() {
        for arguments: [String: MCPValue] in [
            ["pid": .number(1.5)], ["pid": .number(1e20)],
            ["pid": .string("123")], ["timeout": .string("5")],
            ["action": .bool(true)],
        ] {
            XCTAssertThrowsError(try ExtendedMCP.liveRequest(arguments))
        }
        XCTAssertEqual(try ExtendedMCP.liveRequest(["pid": .number(123)]).pid, 123)
    }

    @MainActor
    func testUnavailableDaemonCallHasWarningAndNoVerdict() async {
        let engine = VerdictEngine(
            registry: .init([]),
            baselines: .standard(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        )
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "live_act", live: LiveRequest(pid: 0, path: "field", action: "type", value: "secret")),
            engine: engine
        )
        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.findings?.first?.rule, "live-unavailable")
        XCTAssertEqual(response.findings?.first?.severity, Finding.Severity.warning)
        XCTAssertFalse(response.error?.contains("secret") ?? true)
    }

    @MainActor
    func testPostedInputDoesNotSatisfyUnobservedOutcome() async throws {
        let request = LiveRequest(pid: 1, path: "status", expectText: "Saved", timeout: 0.22)
        let result = try await LiveRuntime.observe(
            request: request, read: { self.tree("Waiting") }, perform: {}
        )
        XCTAssertEqual(result.status, "FAIL")
        XCTAssertFalse(result.settled)
        XCTAssertTrue(result.findings.contains { $0.rule == "live-expectation" })
        XCTAssertTrue(result.findings.contains { $0.rule == "live-settle-timeout" })
    }

    @MainActor
    func testObservedChangeReturnsDeltaAndPass() async throws {
        var saved = false
        let result = try await LiveRuntime.observe(
            request: LiveRequest(pid: 1, path: "status", expectText: "Saved", timeout: 1, detail: "full"),
            read: { self.tree(saved ? "Saved" : "Waiting") }, perform: { saved = true }
        )
        XCTAssertEqual(result.status, "PASS")
        XCTAssertTrue(result.settled)
        XCTAssertFalse(try XCTUnwrap(result.delta.expand()).isEmpty)
        XCTAssertNotNil(result.tree)
    }

    // CTS-F71E763F: the default answer is a summary, not the whole tree.
    @MainActor
    func testDefaultDetailOmitsTheTreeAndFullKeepsIt() async throws {
        var saved = false
        let result = try await LiveRuntime.observe(
            request: LiveRequest(pid: 1, path: "status", expectText: "Saved", timeout: 1),
            read: { self.tree(saved ? "Saved" : "Waiting") }, perform: { saved = true }
        )
        XCTAssertNil(result.tree)
        XCTAssertEqual(result.status, "PASS")
    }

    func testSummaryCapsExamplesCountsEveryRuleAndKeepsTheStatusInputs() {
        let findings = (0..<40).map { index in
            Finding(rule: index.isMultiple(of: 2) ? "offscreen" : "clipped-content",
                    severity: .error, nodeID: "n\(index)", message: "m")
        }
        let summary = LiveRuntime.shape(findings: findings, detail: "summary", maxFindings: nil)
        XCTAssertEqual(summary.examples.count, 10)
        XCTAssertEqual(summary.omitted, 30)
        XCTAssertEqual(summary.counts, ["offscreen": 20, "clipped-content": 20])

        let capped = LiveRuntime.shape(findings: findings, detail: "summary", maxFindings: 3)
        XCTAssertEqual(capped.examples.count, 3)
        XCTAssertEqual(capped.omitted, 37)

        let delta = LiveRuntime.shape(findings: findings, detail: "delta", maxFindings: nil)
        XCTAssertEqual(delta.examples.count, 40)
        XCTAssertNil(delta.counts)
        XCTAssertNil(delta.omitted)

        let full = LiveRuntime.shape(findings: findings, detail: "full", maxFindings: 0)
        XCTAssertEqual(full.examples.count, 0)
        XCTAssertEqual(full.omitted, 40)
    }

    func testInvalidDetailOrNegativeCapIsRefused() {
        XCTAssertThrowsError(try LiveRequest(pid: 1, detail: "everything").validatedTarget())
        XCTAssertThrowsError(try LiveRequest(pid: 1, maxFindings: -1).validatedTarget())
        XCTAssertNoThrow(try LiveRequest(pid: 1, detail: "delta", maxFindings: 0).validatedTarget())
    }

    @MainActor
    func testDeniedInputProducesNoVerdictAndDoesNotLeakValue() async {
        do {
            _ = try await LiveRuntime.observe(
                request: LiveRequest(pid: 1, path: "field", value: "fixture-secret"),
                read: { self.tree("Waiting") },
                perform: { throw NSError(domain: "fixture-secret", code: 1) }
            )
            XCTFail("denied input must not produce a verdict")
        } catch {
            XCTAssertTrue(String(describing: error).contains("unavailable"))
            XCTAssertFalse(String(describing: error).contains("fixture-secret"))
        }
    }
}

// CTS-3DB96403: a briefly busy app answers kAXErrorCannotComplete (-25204); reads retry.
final class LiveRuntimeBusyRetryTests: XCTestCase {
    private struct Other: Error {}
    private let busy = AXReader.Failure.noWindow(axError: AXError.cannotComplete.rawValue)

    func testBusyThenSuccessReturnsTheValueAfterBackoff() async throws {
        var calls = 0
        var slept: [UInt32] = []
        let value = try await LiveRuntime.retryingBusy(pause: { slept.append($0) }) { () -> Int in
            calls += 1
            if calls < 3 { throw self.busy }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(slept, [100, 250])
    }

    func testBusyOnEveryAttemptReportsTheAttemptCount() async {
        var calls = 0
        do {
            _ = try await LiveRuntime.retryingBusy(maxAttempts: 3, pause: { _ in }) { () -> Int in
                calls += 1
                throw self.busy
            }
            XCTFail("expected busy")
        } catch LiveRuntime.Failure.busy(let attempts) {
            XCTAssertEqual(attempts, 3)
            XCTAssertTrue("\(LiveRuntime.Failure.busy(attempts: attempts))".contains("3 read attempts"))
        } catch {
            XCTFail("expected busy, got \(error)")
        }
        XCTAssertEqual(calls, 3)
    }

    func testOtherFailuresAreNotRetried() async {
        var calls = 0
        do {
            _ = try await LiveRuntime.retryingBusy(pause: { _ in }) { () -> Int in
                calls += 1
                throw Other()
            }
            XCTFail("expected the failure")
        } catch {
            XCTAssertTrue(error is Other)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(LiveRuntime.isBusy(AXReader.Failure.noWindow(axError: 0)))
    }
}
