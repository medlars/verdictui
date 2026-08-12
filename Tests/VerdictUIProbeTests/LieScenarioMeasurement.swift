import XCTest

@testable import VerdictUIDemoScenarios
@testable import VerdictUIKernel
@testable import VerdictUIProbe

/// What the PROBE channel reports for each planted lie.
///
/// `no.md` #24: measure the current output first and read it as a finding.
/// These fixtures exist to be misreported, so the value of the whole suite
/// depends on the misreporting actually reaching the tree — a fixture whose lie
/// never lands is a test that passes for the wrong reason forever, and looks
/// exactly like one that works.
///
/// This suite asserts the lie is PRESENT in the in-process tree, and that the
/// inner loop cannot see it. It deliberately does not assert what the witness
/// sees: if both halves lived in one test, a witness that failed to run would
/// be indistinguishable from a lie that never landed.
@MainActor
final class LieScenarioMeasurementTests: XCTestCase {

    private func tree(for fixture: LieFixture) async throws -> SemanticNode {
        try await fixture.makeHost().currentTree()
    }

    private func node(_ id: String, in tree: SemanticNode) throws -> SemanticNode {
        try XCTUnwrap(
            tree.node(withID: id),
            "probe '\(id)' is absent from the tree; the fixture did not render as written")
    }

    private func verdict(for fixture: LieFixture) async throws -> Verdict {
        let tree = try await self.tree(for: fixture)
        return RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: fixture.name)
        )
    }

    // MARK: - Lie 1: text

    func testTheTextLieReachesTheProbeTree() async throws {
        let subject = try node("receipt-total", in: try await tree(for: LieScenarios.all[0]))

        // The probe must carry the CLAIMED text, not the rendered one. If this
        // ever reads the rendered value, the probe started deriving text from
        // the view — a fine outcome, but it would mean this lie is no longer
        // plantable and the fixture has gone inert.
        XCTAssertEqual(
            subject.text, MisreportedTextScenario.claimedText,
            "the probe did not carry the claimed text; this lie is not landing")
        XCTAssertNotEqual(
            MisreportedTextScenario.claimedText, MisreportedTextScenario.renderedText,
            "the fixture's two constants are equal, so it plants no lie at all")
    }

    // MARK: - Lie 2: role

    func testTheRoleLieReachesTheProbeTreeAndSilencesTapTarget() async throws {
        let subject = try node("checkout-action", in: try await tree(for: LieScenarios.all[1]))

        XCTAssertEqual(
            subject.role, .text,
            "the probe did not carry the claimed role; this lie is not landing")

        // The half that makes this lie worth catching: told the truth, the
        // control FAILS tap-target. Misreported, the rule is never asked. Assert
        // the silencing is real rather than assumed — otherwise the fixture
        // demonstrates a wrong label rather than a suppressed verdict.
        XCTAssertLessThan(
            MisreportedRoleScenario.buttonSize.height,
            LintContext.macOSMinimumTapTarget.height,
            "the fixture's button is not actually undersized, so the misreported role "
                + "suppresses nothing and the lie is cosmetic")

        let asReported = try await verdict(for: LieScenarios.all[1])
        XCTAssertFalse(
            asReported.findings.contains { $0.rule == "tap-target" },
            "tap-target fired despite the role lie, so the inner loop would have caught "
                + "this on its own and the fixture proves nothing about the witness")
    }

    // MARK: - Lie 3: accessibility visibility

    func testTheVisibilityLieReachesTheProbeTree() async throws {
        let subject = try node("hidden-submit", in: try await tree(for: LieScenarios.all[2]))

        // The probe sees an ordinary, healthy, correctly-sized button. That is
        // the point: nothing in the in-process channel is wrong, so no rule can
        // fire, and only a witness reading the accessibility tree can notice the
        // control is unreachable.
        XCTAssertEqual(subject.role, .button)
        XCTAssertTrue(subject.isVisible)
        XCTAssertGreaterThanOrEqual(
            InvisibleControlScenario.buttonSize.height,
            LintContext.macOSMinimumTapTarget.height,
            "the fixture's button is undersized, so tap-target would catch it and the "
                + "visibility gap would not be the only thing wrong")
    }

    // MARK: - Every lie must be invisible to the inner loop

    func testNoPlantedLieIsVisibleToTheInnerLoop() async throws {
        // The property that makes cross-validation necessary rather than
        // redundant. If a rule already caught one of these, that fixture would
        // be testing the rule engine while appearing to test the witness — and
        // the wave's headline claim would rest on a fixture the middle loop
        // never had to catch.
        for fixture in LieScenarios.all {
            let verdict = try await verdict(for: fixture)
            XCTAssertEqual(
                verdict.status, .pass,
                "\(fixture.name) is caught by the INNER loop (\(verdict.findings.map(\.rule))), "
                    + "so it does not prove anything about the external witness")
        }
    }

    // MARK: - The control

    func testTheHonestControlPlantsNothingAndPassesTheRules() async throws {
        let fixture = LieScenarios.honestControl
        let subject = try node("honest-label", in: try await tree(for: fixture))

        XCTAssertEqual(
            subject.text, HonestScenario.labelText,
            "the control's probe disagrees with its own rendered text — it is not honest")

        // The control must also be clean by the ordinary rules: one failing for
        // an unrelated reason would make a reconciliation finding
        // indistinguishable from ordinary noise.
        let verdict = try await verdict(for: fixture)
        XCTAssertEqual(
            verdict.status, .pass,
            "the honest control is not clean: \(verdict.findings.map(\.rule))")
    }

    // MARK: - Catalog integrity

    func testEveryPlantedLieIsAccountedForAndDistinct() {
        XCTAssertEqual(
            LieScenarios.all.count, LieScenarios.count,
            "the pinned count and the catalog disagree — a fixture was added without "
                + "extending the tests, or removed without lowering the count")

        // Three lies must corrupt three DIFFERENT channels. A suite planting
        // three geometry lies would report a 100% catch rate while being blind
        // to text and role, and nothing about the count would reveal it.
        XCTAssertEqual(
            Set(LieScenarios.all.map(\.probeID)).count, LieScenarios.all.count,
            "two fixtures name the same probe, so they are not independent lies")

        // The lie catalog must NOT leak into the demo catalog: that array is
        // iterated by the sweep, the CLI and list_scenarios, and a deliberately
        // lying scenario there would be reported to users as a product defect.
        let demoNames = Set(DemoScenarios.all.map(\.name))
        for fixture in LieScenarios.all + [LieScenarios.honestControl] {
            XCTAssertFalse(
                demoNames.contains(fixture.name),
                "\(fixture.name) leaked into DemoScenarios.all")
        }
    }
}
