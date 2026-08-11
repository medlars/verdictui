import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// The daemon's method surface, driven directly.
///
/// `VerdictDaemon.handle` is deliberately separable from the socket plumbing:
/// a daemon whose behaviour can only be observed through a socket is a daemon
/// whose behaviour is mostly untested, and the interesting questions here —
/// does a failing verdict still count as an ANSWERED request, does an unknown
/// method say so — are about the protocol rather than about the transport.
final class DaemonTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-daemon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    @MainActor
    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(root: root)
        )
    }

    // MARK: - Protocol basics

    @MainActor
    func testPingReportsTheSchemaVersion() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "ping", id: "abc"),
            engine: engine()
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "abc", "a correlation id must be echoed untouched")
        guard case .pong(let version)? = response.result else {
            return XCTFail("expected a pong, got \(String(describing: response.result))")
        }
        XCTAssertEqual(version, SchemaVersion.current)
    }

    @MainActor
    func testAnUnknownMethodIsRefusedRatherThanIgnored() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "definitely-not-a-method"),
            engine: engine()
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "unknown method 'definitely-not-a-method'")
    }

    /// A method that needs a scenario and did not get one says THAT, rather
    /// than surfacing "no scenario named ''" from two layers down.
    @MainActor
    func testAMissingScenarioIsReportedAsAMissingArgument() async {
        for method in ["render", "verify", "sweep", "baseline_diff"] {
            let response = await VerdictDaemon.handle(
                DaemonRequest(method: method),
                engine: engine()
            )
            XCTAssertFalse(response.ok, method)
            XCTAssertEqual(
                response.error,
                "method '\(method)' requires a scenario",
                "\(method) must name the missing argument"
            )
        }
    }

    /// The control for the check above: methods that need NO scenario must
    /// still work when none is supplied.
    @MainActor
    func testScenarioFreeMethodsWorkWithoutOne() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "list"),
            engine: engine()
        )

        XCTAssertTrue(response.ok, response.error ?? "")
        guard case .scenarios(let names)? = response.result else {
            return XCTFail("expected scenarios, got \(String(describing: response.result))")
        }
        XCTAssertEqual(Set(names), Set(DemoScenarios.all.map(\.name)))
    }

    // MARK: - The distinction that must survive the wire

    /// A FAILING verdict is an ANSWERED request.
    ///
    /// The daemon's `ok` reports whether it could look, never what it saw.
    /// A client that conflated the two would report an infrastructure fault as
    /// a product defect — the same three-valued contract the CLI's exit codes
    /// carry, one layer out.
    @MainActor
    func testAFailingVerdictIsASuccessfulRequest() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "verify", scenario: "demo-offscreen-button"),
            engine: engine()
        )

        XCTAssertTrue(
            response.ok,
            "the daemon answered — `ok` reports whether it could look, not what it saw"
        )
        guard case .verdict(let verdict)? = response.result else {
            return XCTFail("expected a verdict, got \(String(describing: response.result))")
        }
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(verdict.findings.contains { $0.nodeID == "apply-button" })
    }

    /// An unknown scenario is NOT an answered request.
    @MainActor
    func testAnUnknownScenarioIsAFailedRequestRatherThanAFailingVerdict() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "verify", scenario: "no-such-scenario"),
            engine: engine()
        )

        XCTAssertFalse(
            response.ok,
            "the daemon could not look, so this must not arrive as a verdict a client can read"
        )
        XCTAssertNil(response.result)
        XCTAssertTrue(response.error?.contains("no-such-scenario") == true, response.error ?? "")
    }

    @MainActor
    func testTheCleanScenarioVerifiesThroughTheDaemon() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "verify", scenario: CleanSettingsScenario.scenarioName),
            engine: engine()
        )

        XCTAssertTrue(response.ok, response.error ?? "")
        guard case .verdict(let verdict)? = response.result else {
            return XCTFail("expected a verdict")
        }
        XCTAssertEqual(verdict.status, .pass)
    }

    // MARK: - Wire format

    /// Every response is exactly one newline-terminated JSON document.
    ///
    /// Newline-delimited rather than length-prefixed so a desynchronized socket
    /// fails visibly at the next parse instead of silently consuming the wrong
    /// byte count.
    @MainActor
    func testAResponseEncodesAsOneNewlineTerminatedDocument() async throws {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "ping", id: "x"),
            engine: engine()
        )
        let encoded = try VerdictDaemon.encode(response)

        XCTAssertEqual(encoded.last, 0x0A, "the frame must end in a newline")
        let body = encoded.dropLast()
        XCTAssertFalse(
            body.contains(0x0A),
            "a frame must contain exactly one document — an embedded newline would split it"
        )
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(body)))
    }

    func testARequestRoundTripsThroughTheWire() throws {
        let original = DaemonRequest(
            method: "verify",
            scenario: "demo-clean-settings",
            baseline: true,
            id: "corr-1"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try VerdictDaemon.decode(encoded)

        XCTAssertEqual(decoded, original)
    }

    /// The daemon does not expose the destructive operation.
    ///
    /// `baseline update` replaces the record of what a screen SHOULD be, and a
    /// long-running socket-reachable process is the wrong place to put the one
    /// destructive command in the product. Asserted rather than merely
    /// documented, so adding the method requires deleting this test and saying
    /// why.
    @MainActor
    func testTheDaemonRefusesToUpdateBaselines() async {
        for method in ["baseline_update", "baseline_accept", "accept"] {
            let response = await VerdictDaemon.handle(
                DaemonRequest(method: method, scenario: CleanSettingsScenario.scenarioName),
                engine: engine()
            )
            XCTAssertFalse(response.ok, "\(method) must not be served")
            XCTAssertTrue(
                response.error?.contains("unknown method") == true,
                "\(method): \(response.error ?? "")"
            )
        }
    }
}
