import Foundation
import XCTest
import VerdictUIKernel
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
            request: LiveRequest(pid: 1, path: "status", expectText: "Saved", timeout: 1),
            read: { self.tree(saved ? "Saved" : "Waiting") }, perform: { saved = true }
        )
        XCTAssertEqual(result.status, "PASS")
        XCTAssertTrue(result.settled)
        XCTAssertFalse(try XCTUnwrap(result.delta.expand()).isEmpty)
        XCTAssertNotNil(result.tree)
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
