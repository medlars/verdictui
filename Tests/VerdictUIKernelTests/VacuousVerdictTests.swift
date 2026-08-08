import XCTest

@testable import VerdictUIKernel

/// A verdict may only report PASS about a tree it could actually observe.
///
/// Every rule iterates children, so a tree with no probed nodes produces zero
/// findings, and zero findings derives to PASS — a verdict that says "this
/// screen is fine" on the strength of having looked at nothing. Measured
/// 2026-08-08 against a real app view (LaunchGate's `PageHeader`) hosted with
/// no `.verdictProbe`: squeezed from its real 720 pt width to 90 pt, visibly
/// broken, it returned PASS with an empty findings array.
///
/// This is the worst failure this product can have, because the whole thesis is
/// telling a coding agent whether a screen is broken, and a vacuous PASS is
/// indistinguishable at the call site from a real one.
///
/// The guard lives in ``RuleEngine/run(rules:on:context:includeTree:)`` rather
/// than in a ``LintRule`` deliberately: a rule can be switched off through
/// ``LintContext/disabledRules``, which would silently reopen exactly this hole.
/// `testTheGuardCannotBeDisabled` pins that.
final class VacuousVerdictTests: XCTestCase {
    /// The shape `OracleHost` produces for a view carrying no probes: a
    /// synthesized root and nothing beneath it.
    private func probelessTree() -> SemanticNode {
        SemanticNode(
            id: "",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 90, height: 120),
            structuralPath: "root"
        )
    }

    private func context() -> LintContext {
        LintContext(scenario: "probeless", viewport: Rect(x: 0, y: 0, width: 90, height: 120))
    }

    func testAProbelessTreeCannotProduceAPassVerdict() {
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: probelessTree(),
            context: context()
        )
        XCTAssertEqual(
            verdict.status, .fail,
            "a tree with no probed nodes was reported PASS — the engine claimed a "
                + "screen is fine on the strength of having observed nothing"
        )
    }

    func testTheVacuousFindingNamesItselfAndCarriesEvidence() throws {
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: probelessTree(),
            context: context()
        )
        let finding = try XCTUnwrap(
            verdict.findings.first { $0.rule == RuleEngine.vacuousVerdictRule },
            "the vacuous verdict must be reported as a finding, not merely by status"
        )
        XCTAssertEqual(finding.severity, .error)
        // The suggestion has to say what to DO. A finding an agent cannot act on
        // trains it to ignore the rule (lesson 209).
        let suggestion = try XCTUnwrap(
            finding.suggestion,
            "a vacuous verdict without a suggestion leaves the reader nowhere to go"
        )
        XCTAssertTrue(
            suggestion.contains("verdictProbe"),
            "the finding must name the fix; got '\(suggestion)'"
        )
    }

    /// The reason this is not a `LintRule`.
    func testTheGuardCannotBeDisabled() {
        var ctx = context()
        ctx.disabledRules = [RuleEngine.vacuousVerdictRule]
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: probelessTree(),
            context: ctx
        )
        XCTAssertEqual(
            verdict.status, .fail,
            "naming the guard in disabledRules switched it off — it must be "
                + "structural precisely so no caller can opt out of it"
        )
    }

    /// Running with NO rules at all is the other way to reach zero findings, and
    /// it must not be mistaken for a clean screen either.
    func testAnEmptyRuleSetOnAProbelessTreeStillFails() {
        let verdict = RuleEngine.run(rules: [], on: probelessTree(), context: context())
        XCTAssertEqual(verdict.status, .fail)
    }

    /// The control. Without this, "fails on a probeless tree" would be satisfied
    /// by an engine that fails on everything.
    func testAProbedCleanTreeStillPasses() {
        let tree = SemanticNode(
            id: "",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "hello",
                    role: .text,
                    frame: Rect(x: 10, y: 10, width: 100, height: 20),
                    text: "hello",
                    structuralPath: "root/text[0]"
                )
            ]
        )
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: LintContext(
                scenario: "probed",
                viewport: Rect(x: 0, y: 0, width: 200, height: 100)
            )
        )
        XCTAssertEqual(
            verdict.status, .pass,
            "a probed, clean tree must still pass; got \(verdict.findings)"
        )
    }

    /// A probe nested below an unprobed container still counts — the search is
    /// over the whole tree, not the root's immediate children.
    func testAProbeNestedDeepCountsAsObservation() {
        let tree = SemanticNode(
            id: "",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "",
                    role: .container,
                    frame: Rect(x: 0, y: 0, width: 200, height: 100),
                    structuralPath: "root/container[0]",
                    children: [
                        SemanticNode(
                            id: "deep",
                            role: .text,
                            frame: Rect(x: 10, y: 10, width: 100, height: 20),
                            text: "deep",
                            structuralPath: "root/container[0]/text[0]"
                        )
                    ]
                )
            ]
        )
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: LintContext(
                scenario: "nested",
                viewport: Rect(x: 0, y: 0, width: 200, height: 100)
            )
        )
        XCTAssertFalse(
            verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule },
            "a nested probe is still an observation — the guard must search the "
                + "whole tree, not just the root's direct children"
        )
    }
}
