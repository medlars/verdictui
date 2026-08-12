import XCTest

@testable import VerdictUIDemoScenarios
@testable import VerdictUIKernel
@testable import VerdictUIProbe
@testable import VerdictUIWitness

/// The honesty proof (Wave 8 Task 4 / SD1): every deliberately planted lie must
/// be caught by the external witness, at a catch rate the plan calls
/// non-negotiable.
///
/// This is the suite the middle loop exists for. `LieScenarioMeasurementTests`
/// already establishes the precondition — each lie reaches the probe tree, and
/// NONE of them is visible to the inner loop — so a catch here can only have
/// come from the external channel. Splitting the two is deliberate: if both
/// halves lived in one test, a witness that silently failed to run would be
/// indistinguishable from a lie that never landed.
///
/// The suite skips loudly where no window server or Accessibility grant exists,
/// because a red meaning "this machine cannot host a window" teaches its reader
/// to discount the result — and this is the one result that must not be
/// discounted.
@MainActor
final class LieCatchTests: XCTestCase {

    private var hostExecutable: URL? {
        let bundle = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
        let candidate = bundle.appendingPathComponent("verdictui-witness-host")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private var isHeadless: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["CODEX_CI"] != nil
            || environment["VERDICTUI_SKIP_WITNESS"] != nil
    }

    /// Reconcile one fixture across both channels.
    private func findings(for fixture: LieFixture) async throws -> [Finding] {
        let executable = try XCTUnwrap(
            hostExecutable, "verdictui-witness-host was not built alongside the tests")
        let internalTree = try await fixture.makeHost().currentTree()
        let witness = WitnessHostProcess(executable: executable, lifetime: 20)
        return CrossValidation.findings(internalTree: internalTree) {
            try witness.readTree(scenario: fixture.name)
        }
    }

    /// Establish that the witness can observe ANYTHING before asking it to
    /// observe a lie — with a POSITIVE CONTROL, not a permission flag.
    ///
    /// There is a third environment state beyond "headless" and "no grant", and
    /// it is the one that bites: a session where the window server has stopped
    /// publishing windows for newly-launched GUI apps. Measured 2026-08-12 —
    /// `WitnessIntegrationTests` passed at 17:22:55 and failed at 18:04 with
    /// `Sources/VerdictUIWitness/` byte-identical at HEAD, after a session's
    /// worth of launching and killing an unsigned `.app`. Every host then
    /// reports zero windows, and the read fails with `anchorUnreadable`.
    ///
    /// Without this control the honesty gate goes RED for the machine, which is
    /// the failure `no.md` #15 names: a gate that fails for the environment
    /// teaches its reader to discount it — and this is the one gate that must
    /// never be discounted. `AXIsProcessTrusted()` cannot make the distinction
    /// (it returns `true` throughout, `no.md` #42), so the control is a real
    /// read of a scenario known to be honest.
    private func requireWorkingWitness() async throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(
            AXReader.isTrusted,
            "this process lacks Accessibility permission; grant it to the terminal running tests")

        // The positive control: a scenario that lies about nothing must read
        // cleanly. If even THAT cannot be observed, the witness is not in a
        // state to judge anything and the suite must skip rather than accuse.
        let control = try await findings(for: LieScenarios.honestControl)
        if let blocked = control.first(where: { $0.rule == Reconcile.unavailableRule }) {
            throw XCTSkip(
                "the witness cannot observe its own control on this host, so it cannot "
                    + "judge a lie either: \(blocked.message). This is an ENVIRONMENT state, "
                    + "not a product defect — re-run in a fresh login session.")
        }
    }

    // MARK: - The gate: 100 %, or the feature does not work

    func testEveryPlantedLieIsCaught() async throws {
        try await requireWorkingWitness()

        var missed: [String] = []
        for fixture in LieScenarios.all {
            let findings = try await self.findings(for: fixture)

            // A skipped run is NOT a pass. Without this, a witness that could
            // not read anything would report the unavailable warning, contain
            // no disagreement, and be counted as "caught nothing" — which is
            // the same shape as a working witness finding nothing wrong.
            XCTAssertFalse(
                findings.contains { $0.rule == Reconcile.unavailableRule },
                "\(fixture.name): cross-validation did not RUN, so this says nothing about "
                    + "whether the lie is catchable — \(findings.map(\.message))")

            let caught = findings.contains { $0.rule == fixture.expectedRule }
            if !caught {
                missed.append(
                    "\(fixture.name) — \(fixture.lie); expected \(fixture.expectedRule ?? "?"), "
                        + "got \(findings.map(\.rule))")
            }
        }

        XCTAssertTrue(
            missed.isEmpty,
            "the witness missed \(missed.count) of \(LieScenarios.all.count) planted lies. "
                + "Cross-validation is decorative unless this is zero:\n"
                + missed.joined(separator: "\n"))
    }

    func testEachCaughtLieCitesTheProbeThatLied() async throws {
        try await requireWorkingWitness()

        // A finding that names the wrong node sends the reader at innocent
        // code. Catching the lie and reporting it against a sibling is a
        // half-fix that reads exactly like a whole one in a pass/fail count.
        for fixture in LieScenarios.all {
            let findings = try await self.findings(for: fixture)
            let matching = findings.filter { $0.rule == fixture.expectedRule }
            XCTAssertTrue(
                matching.contains { $0.nodeID.contains(fixture.probeID) },
                "\(fixture.name): the lie was caught but cited "
                    + "\(matching.map(\.nodeID)) rather than '\(fixture.probeID)'")
        }
    }

    /// Why a role lie surfaces as a visibility gap rather than a role
    /// disagreement — pinned so the fixture's expectation is a MECHANISM rather
    /// than a value copied off a passing run.
    ///
    /// `structuralPath` embeds the role (`root/text[1]` against
    /// `root/button[1]`) and is the key the external channel is matched on,
    /// because AX carries no probe ids. So a role lie changes the node's own
    /// identity: the channels never pair it up, and the honest report is "the
    /// probe claims a node AX cannot see".
    ///
    /// This matters beyond bookkeeping. `Reconcile.disagreementRule` fires only
    /// on nodes that MATCHED, so it is structurally unable to see a role lie —
    /// and a reader who assumed otherwise would conclude role lies go
    /// undetected, when in fact they surface under a different rule.
    func testARoleLieIsUnmatchableByConstructionNotMerelyUncaught() {
        let probed = SemanticNode(
            id: "checkout-action",
            role: .text,  // the lie
            frame: Rect(x: 0, y: 0, width: 80, height: 18)
        )
        let published = SemanticNode(
            id: "checkout-action",
            role: .button,  // what the platform publishes
            frame: Rect(x: 0, y: 0, width: 80, height: 18)
        )
        let mine = SemanticNode(
            id: "root", role: .container,
            frame: Rect(x: 0, y: 0, width: 260, height: 120), children: [probed]
        ).withAssignedStructuralPaths()
        let theirs = SemanticNode(
            id: "root", role: .container,
            frame: Rect(x: 0, y: 0, width: 260, height: 120), children: [published]
        ).withAssignedStructuralPaths()

        XCTAssertNotEqual(
            mine.children[0].structuralPath, theirs.children[0].structuralPath,
            "the role is no longer part of the structural path, so a role lie would now "
                + "match and report as a disagreement — update the fixture's expectation")

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)
        XCTAssertEqual(
            findings.map(\.rule), [Reconcile.visibilityGapRule],
            "a role lie must still be CAUGHT, whichever rule reports it")
    }

    // MARK: - The control: silence when there is nothing to report

    func testTheHonestControlProducesNoReconciliationFinding() async throws {
        try await requireWorkingWitness()

        // Without this, a reconciler that flagged every node would catch all
        // three lies and score a perfect 100 %. The catch rate would then be
        // measuring noise rather than detection (`no.md` #17).
        let fixture = LieScenarios.honestControl
        let findings = try await self.findings(for: fixture)

        XCTAssertFalse(
            findings.contains { $0.rule == Reconcile.unavailableRule },
            "the control's cross-validation did not run, so its silence proves nothing")
        XCTAssertTrue(
            findings.isEmpty,
            "the honest control produced \(findings.count) finding(s), so the reconciler "
                + "reports disagreements that are not there: \(findings.map(\.message))")
    }
}
