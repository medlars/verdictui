import XCTest

@testable import VerdictUICLICore
@testable import VerdictUIDemoScenarios
@testable import VerdictUIKernel

/// Wave 8 Task 5: `verify --cross-validate` across the CLI, the daemon and MCP.
///
/// The property under test is not "the flag exists" — it is that requesting
/// cross-validation and NOT requesting it produce distinguishable verdicts, and
/// that a witness which could not run is reported rather than silently dropped.
///
/// Every assertion here pairs with its control. Without the off-path control,
/// "cross-validation ran" is satisfied by an engine that runs it unconditionally
/// — which would make the flag a no-op while every test stayed green, the
/// `no.md` #17 shape.
@MainActor
final class CrossValidateFlagTests: XCTestCase {

    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("verdictui-crossvalidate-\(UUID().uuidString)")
            )
        )
    }

    private let scenario = "demo-clean-settings"

    // MARK: - The flag gates the work

    func testNotRequestingCrossValidationLeavesTheTimingNil() async throws {
        let verdict = try await engine().verify(scenario: scenario)

        // `nil` means NOT REQUESTED. It must not be confused with 0.0, which
        // would read as "cross-validation ran and cost nothing" — a claim the
        // engine is in no position to make.
        XCTAssertNil(
            verdict.timing.crossValidateMs,
            "cross-validation was not requested, so its timing must be absent")
        XCTAssertFalse(
            verdict.findings.contains { $0.rule == Reconcile.unavailableRule },
            "an inner-loop-only verdict must not carry a cross-validation finding")
    }

    func testRequestingCrossValidationAlwaysReportsWhatHappened() async throws {
        let verdict = try await engine().verify(scenario: scenario, crossValidate: true)

        // The timing is populated on BOTH paths — success and failure — because
        // the cost of a failed attempt is real information: "the witness took
        // 4 s to fail" distinguishes a missing grant from a hung host.
        let elapsed = try XCTUnwrap(
            verdict.timing.crossValidateMs,
            "cross-validation was requested, so its cost must be measured whichever way it went")
        XCTAssertGreaterThan(elapsed, 0, "a measured elapsed time cannot be zero")
        XCTAssertTrue(elapsed.isFinite, "the measurement must be a real number")

        // Either it ran (no skipped finding) or it did not (exactly one, naming
        // why). What must never happen is silence: a caller that asked for two
        // channels and received an ordinary PASS would read it as agreement.
        let skipped = verdict.findings.filter { $0.rule == Reconcile.unavailableRule }
        XCTAssertLessThanOrEqual(skipped.count, 1, "at most one skipped finding")
        if let only = skipped.first {
            XCTAssertEqual(only.severity, .warning)
            XCTAssertFalse(
                only.message.isEmpty, "a skipped finding that names no reason cannot be acted on")
        }
    }

    // MARK: - The wire contract

    func testTheSchemaVersionIsTheOneTheContractDeclares() async throws {
        let verdict = try await engine().verify(scenario: scenario)
        XCTAssertEqual(
            verdict.schemaVersion, SchemaVersion.current,
            "the encoder and the version constant disagree")
        XCTAssertEqual(
            SchemaVersion.current, "1.1",
            "Wave 8 adds crossValidateMs, which is an additive minor bump")
    }

    func testCrossValidateMsSurvivesTheWire() throws {
        // A field the engine sets but the encoder drops is invisible to every
        // consumer — and it fails GREEN, because the in-process verdict is
        // correct and nothing compares it to the emitted JSON.
        var verdict = Verdict(scenario: scenario, findings: [])
        verdict.timing.crossValidateMs = 42.5

        let data = try JSONEncoder().encode(verdict)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the verdict did not encode as a JSON object")
        let timing = try XCTUnwrap(raw["timing"] as? [String: Any])

        XCTAssertEqual(
            timing["crossValidateMs"] as? Double, 42.5,
            "crossValidateMs did not reach the wire under the documented key")
    }

    func testAnAbsentCrossValidateMsIsOmittedRatherThanNulled() throws {
        // The contract types it as nullable, so either shape validates — but a
        // consumer counting keys should see the field only when it means
        // something. This pins whichever shape ships so a change is deliberate.
        let verdict = Verdict(scenario: scenario, findings: [])
        let data = try JSONEncoder().encode(verdict)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timing = try XCTUnwrap(raw["timing"] as? [String: Any])

        XCTAssertNil(
            timing["crossValidateMs"],
            "an unrequested cross-validation must not appear in the encoded timing")
    }

    // MARK: - The other two surfaces

    func testTheDaemonForwardsTheFlagRatherThanIgnoringIt() async {
        let requested = await VerdictDaemon.handle(
            DaemonRequest(method: "verify", scenario: scenario, crossValidate: true),
            engine: engine()
        )
        let notRequested = await VerdictDaemon.handle(
            DaemonRequest(method: "verify", scenario: scenario),
            engine: engine()
        )

        guard case .verdict(let withCV)? = requested.result,
            case .verdict(let withoutCV)? = notRequested.result
        else {
            return XCTFail("the daemon did not return verdicts for both requests")
        }

        // The control is the whole test: a daemon that dropped the flag would
        // return two IDENTICAL verdicts, and every assertion about the
        // requested one alone would still pass.
        XCTAssertNotNil(
            withCV.timing.crossValidateMs,
            "the daemon dropped cross_validate — the verdict shows no attempt")
        XCTAssertNil(
            withoutCV.timing.crossValidateMs,
            "the daemon ran cross-validation for a request that did not ask for it")
    }

    func testTheMCPToolDeclaresTheParameterItForwards() throws {
        // A parameter the transport reads but the schema never advertises is
        // unreachable for a real client, which discovers tools by their schema
        // and cannot guess an undocumented key.
        let verify = try XCTUnwrap(
            MCPServer.tools.first { $0.name == "verify" },
            "the verify tool is missing from the catalog")

        XCTAssertNotNil(
            verify.inputSchema.properties["cross_validate"],
            "verify accepts cross_validate but does not declare it, so no client can find it")
        XCTAssertEqual(
            verify.inputSchema.properties["cross_validate"]?.type, "boolean")
    }
}
