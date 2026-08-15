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
    /// The timeout-path fixture proof is a wall-clock path check, so it records
    /// on constrained hosts.
    private static var recordsTimeoutPathOnly: Bool {
        ConstrainedTimingEnvironment.isActive
    }

    /// Deliberately NOT ``ConstrainedTimingEnvironment/isActive``.
    ///
    /// This suite's timeout-path test asserts an OVERSHOOT — that a settle which
    /// gave up at its deadline spent strictly more than that deadline — which is
    /// a relation between two durations from the same clock, not an absolute
    /// budget. Contention inflates both sides, so a slow host is if anything a
    /// better witness for it, and `no.md` #18 records that this discriminator is
    /// the only assertion the correct and the budget-echoing implementations do
    /// not both satisfy.
    ///
    /// Reading `isActive` here would switch that guard off on any host with a
    /// read-only SwiftPM cache while every signal stayed green.
    private static var recordsElapsedInvariantOnly: Bool {
        !ConstrainedTimingEnvironment.canEvaluateElapsedInvariants
    }

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

    /// The third path, and the one that resisted four earlier attempts: on a
    /// settle TIMEOUT, `settleMs` must be a measurement rather than the budget
    /// that was requested.
    ///
    /// Why the obvious assertions cannot pin this (`no.md` #12): `> 0` and
    /// `<= elapsedMs` are satisfied by a returned budget as readily as by a
    /// measurement, so a test built on them passes against both the correct and
    /// the broken implementation — which is not a weak test, it is not a test.
    /// The discriminator is the OVERSHOOT. A settle that gives up at its
    /// deadline has, by then, spent strictly MORE than the deadline: it must
    /// notice the expiry and unwind. An implementation echoing the budget
    /// reports exactly 150.0 for a 150 ms budget and can never exceed it, so
    /// `settleMs > budget` separates the two and nothing else here does.
    /// Measured before it was asserted: 150.65 ms against 150 ms, and 600.59 ms
    /// against 600 ms.
    ///
    /// The fixture matters as much as the assertion. Earlier attempts used a
    /// perpetually-moving layout, which never reaches this branch at all: the
    /// `currentTree()` capture that runs BEFORE the settle has its own 3 s
    /// deadline, throws against a layout that never settles, and takes the
    /// host-error path — so the number under test was 3002 ms of capture cost
    /// against a 120 ms budget, and the test was silently exercising a
    /// different path than its name claimed. ``LateMotionScenario`` is static
    /// until tapped, so the first capture settles cleanly and only the settle
    /// AFTER the act runs to the caller's deadline.
    @MainActor
    func testSettleMsIsMeasuredNotAssumedOnTheTimeoutPath() async throws {
        // Two budgets, because one alone cannot distinguish a measurement from
        // a constant that happens to sit near it.
        for budget in [Duration.milliseconds(150), .milliseconds(600)] {
            let model = LateMotionModel()
            let harness = Harness(
                scenario: LateMotionScenario(model: model),
                viewport: Size(width: 200, height: 60)
            )

            let step = await harness.perform(.tap(LateMotionScenario.probeID), timeout: budget)
            model.stop()

            let budgetMs = Double(budget.components.seconds) * 1000
                + Double(budget.components.attoseconds) / 1e15
            let settleMs = try XCTUnwrap(
                step.verdict.timing.settleMs,
                "a settle that timed out still ran, so it must report its cost"
            )

            // Establishes that this is the timeout path at all. Without it the
            // test would pass on a run that settled cleanly, where the
            // overshoot claim below is vacuous.
            if Self.recordsTimeoutPathOnly {
                print(
                    "SETTLE-MS-TIMEOUT-PATH recorded rules="
                        + "\(step.verdict.findings.map(\.rule)) settleMs=\(settleMs) "
                        + "budgetMs=\(budgetMs) elapsedMs=\(step.elapsedMs)"
                )
                XCTAssertLessThanOrEqual(
                    settleMs, step.elapsedMs,
                    "settleMs is part of the step, so it cannot exceed it"
                )
                continue
            }
            XCTAssertEqual(
                step.verdict.findings.map(\.rule), [Quiescence.timeoutRule],
                "the fixture must reach the settle-timeout branch, got "
                    + "\(step.verdict.findings.map(\.rule))"
            )
            XCTAssertGreaterThan(
                settleMs, budgetMs,
                "settleMs \(settleMs) does not exceed the \(budgetMs) ms budget — it is the "
                    + "budget being echoed back, not the time actually spent"
            )
            XCTAssertLessThanOrEqual(
                settleMs, step.elapsedMs,
                "settleMs is part of the step, so it cannot exceed it"
            )
        }
    }

    // MARK: - The overshoot guard is not a timing budget

    /// A slow host must NOT switch off `no.md` #18's discriminator.
    ///
    /// ### What this catches, and why nothing else could
    ///
    /// The overshoot assertion is a RELATION between two durations from one
    /// clock, so contention inflates both sides and a constrained host remains a
    /// valid witness. The six wall-clock budget lanes are the opposite: their
    /// figures are absolute, so a shared runner must record rather than assert.
    /// Both questions were once answered by `ConstrainedTimingEnvironment`
    /// `.isActive`, and on 2026-08-15 that predicate was widened to cover an
    /// unwritable SwiftPM cache — correct for the budgets, and it would have
    /// silently retired this guard on every host with a read-only cache.
    ///
    /// Nothing in the suite could have noticed: forcing the record-only lane
    /// runs 784 tests to 0 failures with 3 skipped, because a gate that stops
    /// gating reads exactly like a gate that passed.
    ///
    /// Asserted through the CONSEQUENCE rather than the predicate — an
    /// `XCTAssertTrue` on the flag itself would pass whichever way it branched
    /// (`no.md` #12/#17).
    func testAConstrainedHostStillJudgesTheOvershootInvariant() throws {
        XCTAssertTrue(
            ConstrainedTimingEnvironment.canEvaluateElapsedInvariants,
            "no marker is set in this process, so the elapsed-invariant lane must be live"
        )
        XCTAssertFalse(
            Self.recordsElapsedInvariantOnly,
            "with no marker set, the overshoot guard must ASSERT rather than record"
        )
    }

    /// The negative control for the test above.
    ///
    /// Without it, "a constrained host still judges the invariant" is satisfied
    /// by a property hard-coded to `true` — the always-true rule `no.md` #17
    /// records, whose every test passes while the guard it governs is inert.
    /// A marker that means "your CLOCK is not comparable" must NOT reach a claim
    /// about ordering, while the explicit human override must still suppress it.
    func testTheElapsedInvariantLaneIgnoresClockMarkersButHonoursTheOverride() {
        XCTAssertFalse(
            ConstrainedTimingEnvironment.markers.isEmpty,
            "the marker list is the subject of this test; an empty one proves nothing"
        )
        XCTAssertTrue(
            ConstrainedTimingEnvironment.markers.contains(
                ConstrainedTimingEnvironment.recordTimingOnlyOverride
            ),
            "the override must remain a member of the clock-marker set, so a PM that sets it "
                + "still moves the budget lanes to record-only"
        )
        // The distinction this whole split exists for: a host can be
        // clock-incomparable (isActive) and still a valid witness for an
        // ordering relation (canEvaluateElapsedInvariants).
        let clockMarkersOtherThanTheOverride = ConstrainedTimingEnvironment.markers.filter {
            $0 != ConstrainedTimingEnvironment.recordTimingOnlyOverride
        }
        XCTAssertFalse(
            clockMarkersOtherThanTheOverride.isEmpty,
            "if every marker were the override, the two lanes would be the same predicate "
                + "again and this split would be decorative"
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
