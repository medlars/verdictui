import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// Drives the real command objects in-process.
///
/// Every assertion here goes through the same types `main.swift` calls, so a
/// defect in the command surface fails a test rather than only failing a user.
/// This is the reason `VerdictUICLICore` is a library at all: nothing inside an
/// executable target is reachable from a test in the same package, so command
/// logic living in the executable would be verified by nothing.
final class VerdictEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-cli-tests-\(UUID().uuidString)")
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
    private func environment() -> (CommandEnvironment, CapturedOutput) {
        let output = CapturedOutput()
        let engine = VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(root: root)
        )
        return (
            CommandEnvironment(
                engine: engine,
                output: output,
                // Under the test's own temporary root, so a command that writes
                // images cannot deposit them in the repository.
                pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)
            ),
            output
        )
    }

    // MARK: - list

    @MainActor
    func testListNamesEveryDemoScenario() async throws {
        let (environment, output) = self.environment()
        let code = await ListCommand().run(environment, pretty: false)

        XCTAssertEqual(code, .pass)
        let names = try JSONDecoder().decode(
            [String].self,
            from: Data(output.standardOutput.utf8)
        )
        XCTAssertEqual(
            Set(names),
            Set(DemoScenarios.all.map(\.name)),
            "the CLI registry and the catalog disagree about which scenarios exist — one of "
                + "them was extended without the other"
        )
        XCTAssertTrue(output.standardError.isEmpty, "a successful list writes nothing to stderr")
    }

    // MARK: - verify

    /// The clean scenario is the catalog's reference correct layout, so this is
    /// the CLI's own false-positive guard.
    @MainActor
    func testVerifyingTheCleanScenarioPassesAndExitsZero() async throws {
        let (environment, output) = self.environment()
        let code = await VerifyCommand(scenario: CleanSettingsScenario.scenarioName)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .pass, "stderr was: \(output.standardError)")
        let verdict = try JSONDecoder().decode(
            Verdict.self,
            from: Data(output.standardOutput.utf8)
        )
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertEqual(verdict.findings.map(\.rule), [])
    }

    /// A failing verdict is exit 1 — and the JSON is still complete, because an
    /// agent parses the document on both paths.
    @MainActor
    func testVerifyingADefectiveScenarioFailsWithACitedFinding() async throws {
        let (environment, output) = self.environment()
        let code = await VerifyCommand(scenario: "demo-offscreen-button")
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .verdictFailed)
        let verdict = try JSONDecoder().decode(
            Verdict.self,
            from: Data(output.standardOutput.utf8)
        )
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "offscreen" && $0.nodeID == "apply-button" },
            "a FAIL verdict must cite the rule and the node — bare booleans are banned in the "
                + "public API. Got: \(verdict.findings.map { "\($0.rule)/\($0.nodeID)" })"
        )
    }

    /// The three-valued exit code, and the case that makes it worth having.
    ///
    /// An unknown scenario is exit 2, NOT exit 1: a caller reading exit 1 as
    /// "the UI is wrong" would open a bug against a screen the tool never
    /// looked at.
    @MainActor
    func testAnUnknownScenarioIsUnverifiableRatherThanFailing() async throws {
        let (environment, output) = self.environment()
        let code = await VerifyCommand(scenario: "no-such-scenario")
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(
            code,
            .couldNotVerify,
            "an unknown scenario must not exit 1 — that code means a verdict was produced and "
                + "it failed, which would blame a UI the tool never rendered"
        )
        XCTAssertTrue(
            output.standardOutput.isEmpty,
            "stdout is a contract: one complete document or nothing. Got: "
                + output.standardOutput
        )
        XCTAssertTrue(
            output.standardError.contains("no-such-scenario"),
            "the error must name what was asked for: \(output.standardError)"
        )
        XCTAssertTrue(
            output.standardError.contains(CleanSettingsScenario.scenarioName),
            "the error must list what IS available, or the user is left guessing: "
                + output.standardError
        )
    }

    // MARK: - The baseline round trip (Wave 5 exit gate item 2)

    /// create → mutate → FAIL with a cited delta → --accept → PASS, with an
    /// audit-log entry present.
    ///
    /// The whole gate item in one test, driven through the CLI commands rather
    /// than the store, because the gate is a claim about the TOOL. The mutation
    /// is a viewport change rather than a source edit: it moves real geometry,
    /// which is what a baseline records, and needs no recompile mid-test.
    @MainActor
    func testTheBaselineRoundTripCreatesFailsAcceptsAndLogs() async throws {
        let (environment, output) = self.environment()
        let scenario = CleanSettingsScenario.scenarioName

        // 1. Create. No --accept needed: nothing is being destroyed.
        let created = await BaselineCommand(scenario: scenario, mode: .update(accepted: false))
            .run(environment, pretty: false)
        XCTAssertEqual(created, .pass, "stderr: \(output.standardError)")
        XCTAssertTrue(environment.engine.baselines.exists(scenario: scenario))

        // 2. A fresh render of the same scenario still matches.
        let unchanged = await BaselineCommand(scenario: scenario, mode: .diff)
            .run(environment, pretty: false)
        XCTAssertEqual(
            unchanged,
            .pass,
            "a scenario compared against a baseline recorded from the same render must match — "
                + "a mismatch here means the canonical form is not stable across renders"
        )

        // 3. Mutate: replace the stored baseline with a DIFFERENT geometry, so
        //    the live render now drifts from what is on disk.
        let drifted = try await environment.engine.render(
            scenario: scenario,
            viewport: Size(width: 420, height: 300)
        )
        try environment.engine.baselines.update(
            scenario: scenario,
            tree: drifted,
            accepted: true
        )

        let failing = await BaselineCommand(scenario: scenario, mode: .diff)
            .run(environment, pretty: false)
        XCTAssertEqual(failing, .verdictFailed, "drift must be reported as a failing comparison")

        // 4. Accept, and confirm the delta was SHOWN before it was accepted.
        let beforeAccept = output.standardError
        let accepted = await BaselineCommand(scenario: scenario, mode: .update(accepted: true))
            .run(environment, pretty: false)
        XCTAssertEqual(accepted, .pass)
        XCTAssertTrue(
            output.standardError.count > beforeAccept.count,
            "SD4 requires the destructive command to print what it is about to replace; "
                + "nothing new reached stderr during the accept"
        )

        // 5. Now it passes.
        let afterAccept = await BaselineCommand(scenario: scenario, mode: .diff)
            .run(environment, pretty: false)
        XCTAssertEqual(afterAccept, .pass, "after accepting, the live render is the baseline")

        // 6. The audit log recorded every replacement.
        let entries = try environment.engine.baselines.auditEntries()
        XCTAssertEqual(
            entries.count,
            2,
            "two replacements happened (the planted drift and the accept), so two lines must "
                + "be logged. Got: \(entries)"
        )
        XCTAssertTrue(entries.allSatisfy { $0.contains("superseded-sha256=") })
    }

    /// The refusal, exercised through the command rather than the store.
    @MainActor
    func testUpdatingAnExistingBaselineWithoutAcceptIsRefusedAndWritesNothing() async throws {
        let (environment, output) = self.environment()
        let scenario = CleanSettingsScenario.scenarioName

        _ = await BaselineCommand(scenario: scenario, mode: .update(accepted: false))
            .run(environment, pretty: false)
        let original = try environment.engine.baselines.load(scenario: scenario)

        let code = await BaselineCommand(scenario: scenario, mode: .update(accepted: false))
            .run(environment, pretty: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("--accept"), output.standardError)
        XCTAssertEqual(
            try environment.engine.baselines.load(scenario: scenario).tree,
            original.tree,
            "the refused update must leave the baseline byte-identical"
        )
    }

    // MARK: - sweep

    @MainActor
    func testSweepRendersEveryCellAndReportsPerCellVerdicts() async throws {
        let (environment, output) = self.environment()
        let code = await SweepCommand(
            scenario: CleanSettingsScenario.scenarioName,
            locales: ["en_US", "de_DE"],
            colorSchemes: ["light", "dark"]
        ).run(environment, pretty: false)

        XCTAssertEqual(code, .pass, "stderr: \(output.standardError)")
        let report = try JSONDecoder().decode(
            SweepReportWire.self,
            from: Data(output.standardOutput.utf8)
        )
        XCTAssertEqual(report.cells.count, 4, "2 locales × 2 schemes is 4 cells")
        XCTAssertTrue(
            report.cells.allSatisfy(\.wasMeasured),
            "a cell with no verdict is unmeasured, and the command must not have reported pass"
        )
        XCTAssertEqual(
            Set(report.cells.map(\.variant)).count,
            4,
            "four cells must carry four DISTINCT variant names, or the report cannot say which "
                + "environment produced which result"
        )
    }

    /// A registry entry could not forward a variant to its host until Wave 6 —
    /// the closure signature dropped it — so `verdictui sweep` would have
    /// rendered the baseline environment for every cell while labelling each
    /// with its variant name.
    ///
    /// `SweepTests.testVariantsActuallyChangeTheRenderedTree` covers the same
    /// property through `Sweep`, which builds its own hosts. This covers the
    /// REGISTRY path, which is the one the CLI takes and the one that was
    /// broken.
    @MainActor
    func testASweptRegistryEntryActuallyAppliesItsVariant() async throws {
        let entry = try XCTUnwrap(DemoScenarios.registry.entry(named: "demo-toggle-layout"))

        let leftToRight = try await entry.host(
            variant: Variant(localeIdentifier: "en_US", layoutDirection: .leftToRight)
        ).currentTree()
        let rightToLeft = try await entry.host(
            variant: Variant(localeIdentifier: "ar_SA", layoutDirection: .rightToLeft)
        ).currentTree()

        let ltrX = try XCTUnwrap(leftToRight.node(withID: "collapsed-summary")?.frame.x)
        let rtlX = try XCTUnwrap(rightToLeft.node(withID: "collapsed-summary")?.frame.x)

        XCTAssertNotEqual(
            ltrX,
            rtlX,
            "mirroring the layout must move the summary's x. Identical values mean the entry "
                + "dropped the variant and both cells rendered the same environment — a sweep "
                + "that runs, reports, and measures one thing N times"
        )
    }
}
