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
            let outcome = Self.classifyCitation(findings: findings, fixture: fixture)
            XCTAssertEqual(
                outcome, .cited, outcome.message(for: fixture, findings: findings))
        }
    }

    /// Which of the two DIFFERENT failures happened — because they need
    /// opposite investigations and this gate used to report them identically.
    ///
    /// The old assertion filtered to findings carrying `expectedRule` and then
    /// asserted one of them cited the probe, with the message "the lie was
    /// caught but cited \(matching) rather than \(probeID)". When that filter
    /// came back EMPTY the message rendered as "caught but cited []" — asserting
    /// the lie WAS caught while reporting the evidence that it was NOT. An empty
    /// match means zero findings carried the rule at all, which is a MISS; a
    /// non-empty match citing the wrong node is a MIS-CITATION. Reporting a miss
    /// in the vocabulary of a mis-citation sends the reader at the citation
    /// logic when the question is why nothing fired — measured on
    /// CIS-2C757660, where "caught but cited []" cost four investigation rounds
    /// aimed at matching and paths before anyone questioned the wording.
    ///
    /// Same family as no.md #55 and lesson 260: two opposite findings must never
    /// share a value, or a report, and "I could not see it" is not "I saw it and
    /// it was wrong".
    nonisolated enum CitationOutcome: Equatable {
        /// A finding under the expected rule cites the lying probe.
        case cited
        /// No finding carried the expected rule — the lie was not caught here.
        case missed
        /// The rule fired, but every finding named some other node.
        case misCited
    }

    /// Pure so it is provable without a window server: the three states are
    /// unit-tested from Finding arrays, and therefore stay verified on a machine
    /// too loaded to host the witness at all.
    nonisolated static func classifyCitation(
        findings: [Finding], fixture: LieFixture
    ) -> CitationOutcome {
        let matching = findings.filter { $0.rule == fixture.expectedRule }
        if matching.isEmpty { return .missed }
        if matching.contains(where: { $0.nodeID.contains(fixture.probeID) }) { return .cited }
        return .misCited
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


extension LieCatchTests.CitationOutcome {
    /// Each state gets the vocabulary of what actually happened.
    func message(for fixture: LieFixture, findings: [Finding]) -> String {
        let matching = findings.filter { $0.rule == fixture.expectedRule }
        switch self {
        case .cited:
            return "\(fixture.name): cited correctly"
        case .missed:
            return
                "\(fixture.name): the lie was NOT CAUGHT — no finding carried "
                + "'\(fixture.expectedRule ?? "?")'. This is a MISS, not a mis-citation: "
                + "ask why the rule did not fire, not which node it named. "
                + "rules present: \(findings.map(\.rule)); lie: \(fixture.lie)"
        case .misCited:
            return
                "\(fixture.name): the lie was CAUGHT but cited \(matching.map(\.nodeID)) "
                + "rather than '\(fixture.probeID)' — the rule fired against the wrong "
                + "node, which sends the reader at innocent code"
        }
    }
}

/// Headless proof that the honesty gate can TELL ITS TWO FAILURES APART.
///
/// Deliberately separate from `LieCatchTests`: it needs no window server, no
/// Accessibility grant and no host process, so it stays green on a contended or
/// headless machine — the exact conditions under which CIS-2C757660 could not be
/// reproduced. A gate whose own reporting is only checkable when the machine is
/// quiet is not checkable when it matters.
final class LieCatchCitationReportingTests: XCTestCase {

    private func fixture() -> LieFixture {
        guard let f = LieScenarios.all.first(where: { $0.expectedRule != nil }) else {
            preconditionFailure("no lie fixture carries an expected rule")
        }
        return f
    }

    private func finding(rule: String, nodeID: String) -> Finding {
        Finding(rule: rule, severity: .error, nodeID: nodeID, message: "synthetic")
    }

    func testAnEmptyRuleMatchIsReportedAsAMissNotAMisCitation() {
        let f = fixture()
        // The rule never fired: only an unrelated rule is present.
        let findings = [finding(rule: "some-other-rule", nodeID: f.probeID)]

        let outcome = LieCatchTests.classifyCitation(findings: findings, fixture: f)
        XCTAssertEqual(
            outcome, .missed,
            "zero findings under the expected rule is a MISS; classifying it as a "
                + "mis-citation is the defect CIS-2C757660 recorded")

        let text = outcome.message(for: f, findings: findings)
        XCTAssertTrue(
            text.contains("NOT CAUGHT"),
            "a miss must say the lie was not caught; got: \(text)")
        XCTAssertFalse(
            text.contains("was CAUGHT but cited"),
            "a miss must NOT be reported in the vocabulary of a mis-citation — that is "
                + "the wrong-subject report this test exists to prevent; got: \(text)")
    }

    func testAWrongNodeUnderTheRightRuleIsReportedAsAMisCitation() {
        let f = fixture()
        let findings = [finding(rule: f.expectedRule ?? "", nodeID: "some-innocent-sibling")]

        let outcome = LieCatchTests.classifyCitation(findings: findings, fixture: f)
        XCTAssertEqual(outcome, .misCited)

        let text = outcome.message(for: f, findings: findings)
        XCTAssertTrue(text.contains("was CAUGHT but cited"), "got: \(text)")
        XCTAssertTrue(text.contains("some-innocent-sibling"), "got: \(text)")
    }

    func testTheCorrectCitationPasses() {
        let f = fixture()
        let findings = [finding(rule: f.expectedRule ?? "", nodeID: f.probeID)]
        XCTAssertEqual(LieCatchTests.classifyCitation(findings: findings, fixture: f), .cited)
    }

    func testTheTwoFailureMessagesAreNotInterchangeable() {
        let f = fixture()
        let miss = LieCatchTests.CitationOutcome.missed.message(for: f, findings: [])
        let mis = LieCatchTests.CitationOutcome.misCited.message(
            for: f, findings: [finding(rule: f.expectedRule ?? "", nodeID: "elsewhere")])
        XCTAssertNotEqual(
            miss, mis,
            "the two failures must not render identically — sharing a message is what made "
                + "a miss read as a mis-citation for four investigation rounds")
    }
}
