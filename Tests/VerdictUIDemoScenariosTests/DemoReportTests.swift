import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

/// The executable's body, exercised in-process.
///
/// `VerdictUIDemo/main.swift` is one statement — `print(try await
/// DemoReport.renderJSON())` — precisely so this file can assert on what it
/// prints without spawning it. Spawning would have tested the same code plus a
/// process launch, and would have made the failure message a diff of captured
/// stdout instead of a decoding error that names the field.
final class DemoReportTests: XCTestCase {
    /// See ``DemoScenarioRenderingTests/invokeTest()``: without draining the
    /// pool the hosted AppKit hierarchies accumulate and wedge the suite.
    override func invokeTest() { autoreleasepool { super.invokeTest() } }

    @MainActor
    func testTheReportCarriesOneVerdictPerScenarioInCatalogOrder() async throws {
        let verdicts = try await DemoReport.verdicts()

        XCTAssertEqual(
            verdicts.map(\.scenario),
            DemoScenarios.all.map(\.name),
            "the report and the catalog disagree about which scenarios were run, or in what order"
        )
        XCTAssertEqual(verdicts.count, DemoScenarios.count)
    }

    /// Every verdict states what it cost to settle, because that number is what
    /// SLO 1 (`OracleHost.currentTree()` p95 < 50 ms) is measured from and the
    /// demo run is where it is measured.
    @MainActor
    func testEveryVerdictReportsItsSettleAndEvaluateTiming() async throws {
        for verdict in try await DemoReport.verdicts() {
            let settle = try XCTUnwrap(
                verdict.timing.settleMs,
                "'\(verdict.scenario)' reported no settle time"
            )
            XCTAssertGreaterThan(settle, 0, "'\(verdict.scenario)' settled in no time at all")
            XCTAssertNotNil(
                verdict.timing.evaluateMs,
                "'\(verdict.scenario)' reported no rule-evaluation time"
            )
        }
    }

    /// The output is JSON, and it is the *kernel's* JSON.
    ///
    /// Round-tripping through `JSONDecoder` rather than only checking that the
    /// bytes parse is the stronger assertion for free: `Verdict.init(from:)`
    /// rejects an incompatible schema version, a non-ISO-8601 timestamp, and a
    /// `status` that contradicts its own findings — so a demo that printed a
    /// PASS over an error finding could not survive its own decoder.
    @MainActor
    func testTheReportedJSONDecodesBackIntoTheVerdictsItCameFrom() async throws {
        let json = try await DemoReport.renderJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))

        let decoded = try JSONDecoder().decode([Verdict].self, from: data)
        XCTAssertEqual(
            decoded.map(\.scenario),
            DemoScenarios.all.map(\.name),
            "the printed JSON does not describe the catalog"
        )
        for verdict in decoded {
            XCTAssertEqual(
                verdict.schemaVersion,
                SchemaVersion.current,
                "'\(verdict.scenario)' was printed under a foreign schema version"
            )
            XCTAssertEqual(
                verdict.status,
                Verdict.Status.derived(from: verdict.findings),
                "'\(verdict.scenario)' printed a status its own findings do not support"
            )
            // No tree, deliberately: it dwarfs the findings it explains, and the
            // demo output is meant to be read.
            XCTAssertNil(verdict.tree, "'\(verdict.scenario)' embedded its tree in the report")
        }
    }

    /// The shape a consumer that is not this package sees: a top-level array of
    /// objects, one per scenario, each with the contract's required fields.
    @MainActor
    func testTheReportedJSONIsATopLevelArrayOfVerdictObjects() async throws {
        let json = try await DemoReport.renderJSON()
        let data = try XCTUnwrap(json.data(using: .utf8))

        let parsed = try JSONSerialization.jsonObject(with: data)
        let array = try XCTUnwrap(
            parsed as? [Any],
            "the demo printed something other than a JSON array"
        )
        XCTAssertEqual(array.count, DemoScenarios.count)

        for element in array {
            let object = try XCTUnwrap(element as? [String: Any], "an element was not an object")
            for key in ["schemaVersion", "scenario", "timestamp", "status", "findings", "timing"] {
                XCTAssertNotNil(object[key], "a verdict object is missing '\(key)'")
            }
            let status = try XCTUnwrap(object["status"] as? String)
            XCTAssertTrue(
                ["PASS", "FAIL"].contains(status),
                "a verdict reported status '\(status)'"
            )
        }
    }

    /// The demo is the product's shortest end-to-end path, so it has to end
    /// somewhere other than "everything passed": five of the six scenarios plant
    /// a defect, and a report with no FAIL in it would mean the run rendered
    /// nothing, linted nothing, or lost its findings on the way to stdout.
    @MainActor
    func testTheReportContainsBothOutcomes() async throws {
        let verdicts = try await DemoReport.verdicts()
        let failing = verdicts.filter { $0.status == .fail }.map(\.scenario)
        let passing = verdicts.filter { $0.status == .pass }.map(\.scenario)

        XCTAssertFalse(failing.isEmpty, "no scenario failed, so no planted defect was caught")
        XCTAssertFalse(passing.isEmpty, "every scenario failed, including the clean ones")
        XCTAssertTrue(
            passing.contains(CleanSettingsScenario.scenarioName),
            "the false-positive guard did not pass in the demo run: \(failing)"
        )
    }
}
