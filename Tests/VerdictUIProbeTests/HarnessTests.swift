import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// Wave 3 Task 4: atomic act-and-observe. `perform` must return complete
/// evidence on every path — including the paths where the act or the settle
/// failed — because an agent that gets a thrown error instead of a `StepResult`
/// has no verdict to cite.
final class HarnessTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - Happy path

    @MainActor
    func testPerformReturnsBeforeAfterAndDeltaForARealToggle() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        XCTAssertEqual(step.probeID, ToggleLayoutScenario.toggleProbeID)
        // The before-tree is the collapsed shape; the after-tree is expanded.
        XCTAssertNotNil(step.before.node(withID: "collapsed-summary"))
        XCTAssertNil(step.before.node(withID: "advanced-detail"))

        let after = try? XCTUnwrap(step.after)
        XCTAssertNotNil(after?.node(withID: "advanced-detail"))
        XCTAssertNil(after?.node(withID: "collapsed-summary"))

        guard case .settled = step.settle else {
            XCTFail("a plain toggle must settle, got \(step.settle)")
            return
        }
    }

    /// The delta is the reason `perform` exists as one call rather than three —
    /// pin that it actually describes the structural change, not just that it is
    /// non-empty.
    @MainActor
    func testPerformDeltaNamesTheNodesThatAppearedAndDisappeared() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        let addedIDs = Set(step.delta.added.map(\.node.id))
        let removedIDs = Set(step.delta.removed.map(\.leaf))

        XCTAssertTrue(
            addedIDs.contains("advanced-detail"),
            "expanding must report advanced-detail as added, got \(addedIDs)"
        )
        XCTAssertTrue(
            removedIDs.contains("collapsed-summary"),
            "expanding must report collapsed-summary as removed, got \(removedIDs)"
        )
    }

    @MainActor
    func testPerformPopulatesTimingAndElapsed() async throws {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        XCTAssertGreaterThan(
            step.elapsedMs, 0,
            "elapsedMs is the agent's cost signal; zero means it was never measured"
        )
        let settleMs = try XCTUnwrap(
            step.verdict.timing.settleMs,
            "settleMs must be recorded — a nil reads as 'never measured'"
        )
        XCTAssertGreaterThanOrEqual(settleMs, 0)
        // The step cannot be cheaper than the settle it contains.
        XCTAssertGreaterThanOrEqual(step.elapsedMs, settleMs)
    }

    /// A clean scenario must produce a PASS with no findings — otherwise every
    /// FAIL assertion below would be indistinguishable from a harness that
    /// always fails.
    @MainActor
    func testCleanScenarioPerformIsAPass() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        XCTAssertEqual(
            step.status, .pass,
            "unexpected findings: \(step.verdict.findings.map(\.message))"
        )
    }

    /// `settleMs` must mean ONE thing on every path: wall-clock actually spent
    /// settling, and 0 when no settle ran.
    ///
    /// It used to mean four things — total elapsed including `currentTree`'s
    /// own pump on the capture-failure path, a hardcoded 0 on both act-failure
    /// paths despite real elapsed time, and the REQUESTED timeout (an assumed
    /// value, not a measurement) on the settle-timeout path. A consumer
    /// aggregating `settleMs` across steps was summing incommensurable
    /// quantities, and the timeout path in particular reported a number nobody
    /// measured.
    @MainActor
    func testSettleMsIsZeroWhenNoSettleRan() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        // A rejected act returns before settle is ever called.
        let step = await harness.perform(.toggle("no-such-probe"))

        XCTAssertEqual(step.status, .fail)
        XCTAssertEqual(
            step.verdict.timing.settleMs, 0,
            "no settle ran, so settleMs must be 0 — not elapsed time, not a budget"
        )
        // elapsedMs still measures the step, so the two are distinguishable.
        XCTAssertGreaterThan(step.elapsedMs, 0)
    }

    /// On the happy path `settleMs` is a real measurement bounded by the step.
    @MainActor
    func testSettleMsIsMeasuredNotAssumedOnTheSettlePath() async throws {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))
        let settleMs = try XCTUnwrap(step.verdict.timing.settleMs)

        XCTAssertGreaterThan(settleMs, 0, "a settle that ran must report its cost")
        XCTAssertLessThanOrEqual(
            settleMs, step.elapsedMs,
            "settleMs is part of the step, so it cannot exceed it"
        )
    }

    // MARK: - Act failure is a verdict, not a throw

    @MainActor
    func testUnknownProbeIDBecomesAFailVerdictNamingTheProbe() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle("no-such-probe"))

        XCTAssertEqual(step.status, .fail)
        XCTAssertEqual(step.probeID, "no-such-probe")

        let finding = step.verdict.findings.first { $0.rule == Harness.actionErrorRule }
        let unwrapped = try? XCTUnwrap(finding, "expected a \(Harness.actionErrorRule) finding")
        XCTAssertEqual(
            unwrapped?.nodeID, "no-such-probe",
            "the finding must cite the probe id the agent asked for"
        )
        XCTAssertEqual(unwrapped?.severity, .error)
        XCTAssertNotNil(
            unwrapped?.suggestion,
            "an act failure an agent can fix must carry a machine-actionable hint"
        )
    }

    /// A failed act must leave the tree untouched: before == after, empty delta.
    /// Otherwise an agent could read a phantom change out of a no-op step.
    @MainActor
    func testFailedActLeavesTheTreeUnchanged() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let step = await harness.perform(.toggle("no-such-probe"))

        XCTAssertEqual(step.after, step.before)
        XCTAssertTrue(step.delta.isEmpty, "a rejected act must not report a delta")
    }

    /// Type mismatch is a distinct `ProbeActionError` case and must survive into
    /// the verdict rather than being flattened into "unknown probe".
    @MainActor
    func testTypeMismatchIsAFailVerdictCitingTheProbe() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        // The toggle probe has a bool binding, not a string one.
        let step = await harness.perform(
            .setText(ToggleLayoutScenario.toggleProbeID, "not a bool")
        )

        XCTAssertEqual(step.status, .fail)
        let finding = step.verdict.findings.first { $0.rule == Harness.actionErrorRule }
        XCTAssertEqual(finding?.nodeID, ToggleLayoutScenario.toggleProbeID)
    }

    // MARK: - Flow batching

    @MainActor
    func testRunExecutesEveryStepWhenAllPass() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let flow: [ProbeAction] = [
            .toggle(ToggleLayoutScenario.toggleProbeID),
            .toggle(ToggleLayoutScenario.toggleProbeID),
        ]
        let result = await harness.run(flow)

        XCTAssertEqual(result.steps.count, 2)
        XCTAssertFalse(result.stoppedEarly)
        XCTAssertEqual(result.status, .pass)
        XCTAssertGreaterThan(result.totalElapsedMs, 0)
    }

    /// Two toggles must land back where they started — this is what makes
    /// "two atomic steps, no interleaving" observable.
    @MainActor
    func testRunStepsAreAtomicAndOrdered() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let result = await harness.run([
            .toggle(ToggleLayoutScenario.toggleProbeID),
            .toggle(ToggleLayoutScenario.toggleProbeID),
        ])

        XCTAssertEqual(result.steps.count, 2)
        // Step 1 expanded; step 2 collapsed back.
        XCTAssertNotNil(result.steps[0].after?.node(withID: "advanced-detail"))
        XCTAssertNil(result.steps[1].after?.node(withID: "advanced-detail"))
        // Step 2's before must be step 1's after — no gap where state could leak.
        XCTAssertEqual(result.steps[1].before, result.steps[0].after)
    }

    @MainActor
    func testRunStopsEarlyOnTheFirstFailure() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let result = await harness.run([
            .toggle("no-such-probe"),
            .toggle(ToggleLayoutScenario.toggleProbeID),
        ])

        XCTAssertEqual(result.steps.count, 1, "the second action must never run")
        XCTAssertTrue(result.stoppedEarly)
        XCTAssertEqual(result.status, .fail)
    }

    /// A failure in the FINAL step still stops the flow, but nothing was skipped.
    /// `stoppedEarly` reports *skipped work*, not *failure* — pinning it here so
    /// the two cannot be conflated later.
    @MainActor
    func testFinalStepFailureIsAFailButNotStoppedEarly() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let result = await harness.run([
            .toggle(ToggleLayoutScenario.toggleProbeID),
            .toggle("no-such-probe"),
        ])

        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.status, .fail)
        XCTAssertFalse(
            result.stoppedEarly,
            "nothing was skipped — stoppedEarly must mean skipped work, not failure"
        )
    }

    @MainActor
    func testEmptyFlowIsAPassWithNoSteps() async {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        let result = await harness.run([])

        XCTAssertTrue(result.steps.isEmpty)
        XCTAssertFalse(result.stoppedEarly)
        XCTAssertEqual(result.status, .pass)
        XCTAssertEqual(result.totalElapsedMs, 0)
    }

    // MARK: - includeTree seam

    @MainActor
    func testIncludeTreeControlsWhetherTheVerdictCarriesTheTree() async {
        let bare = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport,
            includeTree: false
        )
        let withTree = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport,
            includeTree: true
        )

        let bareStep = await bare.perform(.toggle(ToggleLayoutScenario.toggleProbeID))
        let treeStep = await withTree.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        XCTAssertNil(bareStep.verdict.tree)
        XCTAssertNotNil(treeStep.verdict.tree)
        // Both must still carry the delta — the tree is the optional part.
        XCTAssertFalse(bareStep.delta.isEmpty)
        XCTAssertFalse(treeStep.delta.isEmpty)
    }

    /// `includeTree` must also hold on the ACT-FAILURE path, where the code
    /// takes an entirely separate return. A seam honoured only on the happy
    /// path is a seam an agent cannot rely on.
    @MainActor
    func testIncludeTreeIsHonouredOnTheActFailurePath() async {
        let withTree = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport,
            includeTree: true
        )

        let step = await withTree.perform(.toggle("no-such-probe"))

        XCTAssertEqual(step.status, .fail)
        XCTAssertNotNil(
            step.verdict.tree,
            "includeTree must hold on the failure path too"
        )
    }

    // MARK: - Rule wiring

    /// The harness lints the AFTER tree with its own `rules`. Swapping in an
    /// empty rule set must silence findings — proof the rules it runs are the
    /// rules it was given, not a hardcoded set.
    @MainActor
    func testHarnessUsesTheRulesItWasGiven() async {
        let harness = Harness(
            scenario: OverlappingBadgesScenario(),
            viewport: OverlappingBadgesScenario.recommendedViewport,
            rules: []
        )

        let step = await harness.perform(
            .custom("noop") { _ in }
        )

        XCTAssertTrue(
            step.verdict.findings.isEmpty,
            "an empty rule set must produce no lint findings, got \(step.verdict.findings)"
        )
        XCTAssertEqual(step.status, .pass)
    }

    /// The control for the test above: the same scenario WITH the standard rules
    /// must fail. Without this, an empty-findings result could mean the rules
    /// never ran at all rather than that they were correctly suppressed.
    @MainActor
    func testStandardRulesCatchThePlantedDefectAfterAnAction() async {
        let harness = Harness(
            scenario: OverlappingBadgesScenario(),
            viewport: OverlappingBadgesScenario.recommendedViewport
        )

        let step = await harness.perform(
            .custom("noop") { _ in }
        )

        XCTAssertEqual(
            step.status, .fail,
            "OverlappingBadgesScenario plants a defect the standard rules must catch"
        )
    }
}
