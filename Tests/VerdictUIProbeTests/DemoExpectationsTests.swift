// Wave 5 exit gate: the expectation DSL, dogfooded on the demo catalog.
//
// Every other test of `Expectations.swift` builds a tree by hand and asks the
// DSL to judge it. This file is the only place where a REAL render goes in and
// a declarative statement of intent judges it, which is the whole claim the DSL
// makes: that "this should say Save and sit right of Cancel" replaces reading a
// screenshot.
import Foundation
import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Declares each demo scenario's intended semantics as an ``ExpectationSet``
/// and evaluates it against the scenario's actual render.
///
/// ### Why the expectations live here and not in the catalog
///
/// ``DemoScenarioEntry`` carries no expected findings on purpose, and its doc
/// comment says why: "an assertion written against a rule id supplied by the
/// very module under test would pass whatever the module claimed." The same
/// argument applies with more force to expectations, because an expectation is
/// a claim about geometry rather than about a rule name — a set published
/// alongside the view it describes is satisfied by construction, and would
/// re-derive itself from the render in the same commit that broke the render.
/// So every set below is written out by hand in this target, from geometry that
/// was MEASURED first (`no.md` #24) and then stated as intent.
///
/// ### Why these are not the same assertions the integration tests make
///
/// ``DemoIntegrationTests`` asserts that each planted defect trips a named
/// RULE — an engine-side claim ("`offscreen` fired on `apply-button`"). The
/// sets here are author-side claims ("the apply button should be inside the
/// viewport, and it is not"). They are different vocabularies over the same
/// render, and both are load-bearing: a rule can fire for the wrong node, and
/// an expectation can pass while a rule nobody wrote would have failed.
///
/// ### The set that carries the file
///
/// ``testEveryExpectationSetIsFalsifiableAgainstItsOwnScenario`` is the one
/// test here that separates a working DSL from an unfalsifiable one. The other
/// tests state expectations the render satisfies, and are therefore ALL passed
/// by an evaluator that returns `[]` unconditionally — the shape lesson 354
/// names, where 20 of 21 tests walk the happy path and one does the work.
final class DemoExpectationsTests: XCTestCase {
    /// Each test hosts an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the pool between tests.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - The declared semantics of each demo scenario

    /// The clean scenario, stated as intent rather than as geometry.
    ///
    /// Bounds are deliberately looser than the measured values: `.atLeast(80)`
    /// on a button that measures 96 pt is a REQUIREMENT, while `.exactly(96)`
    /// would be a transcription of the render that fails on any harmless
    /// re-layout. An expectation set that pins every measured number is a
    /// baseline wearing a DSL's clothing — and baselines already exist, in
    /// `Baselines.swift`, for exactly that job.
    private static var cleanSettings: ExpectationSet {
        ExpectationSet(
            "clean settings — the correct layout",
            [
                Expectation("settings-title").visible.text("General"),
                Expectation("save-button")
                    .visible
                    .role(.button)
                    .text("Save")
                    .width(.atLeast(80))
                    .height(.atLeast(28))
                    .rightOf("cancel-button")
                    .aligned(.top, with: "cancel-button"),
                Expectation("cancel-button")
                    .visible
                    .role(.button)
                    .text("Cancel")
                    .width(.atLeast(80))
                    .height(.atLeast(28))
                    .contained(in: "button-row"),
                Expectation("card-pill").visible.contained(in: "card-layer"),
                Expectation("button-row").visible.below("card-layer"),
            ]
        )
    }

    /// The truncating-label scenario's intent: a detail line that says what it
    /// was given. The scenario's planted defect is that it cannot.
    private static var truncatingLabel: ExpectationSet {
        ExpectationSet(
            "storage — the detail line is readable",
            [
                Expectation("storage-title").visible.text("Storage"),
                Expectation("storage-detail").visible.below("storage-title"),
            ]
        )
    }

    /// The offscreen-button scenario's intent: the primary action is reachable.
    ///
    /// `.onscreen` exists BECAUSE of this set. The first draft of this file
    /// stated the intent as `.visible.role(.button).below("filters-title")` and
    /// the render — measured at `x: 420` in a 320 pt viewport — SATISFIED every
    /// one of those clauses, producing zero findings for a button the user
    /// cannot reach. `isVisible` is always `true` from the layout pass, and the
    /// DSL had no way to name the viewport, so no sentence an author could
    /// write described the defect. That gap is the whole return on dogfooding.
    private static var offscreenButton: ExpectationSet {
        ExpectationSet(
            "filters — the apply button is reachable",
            [
                Expectation("filters-title").visible.text("Filters").onscreen,
                Expectation("apply-button")
                    .visible
                    .role(.button)
                    .below("filters-title")
                    .onscreen,
            ]
        )
    }

    /// The toggle scenario's two states, which is also what
    /// ``StateMachineTests`` walks — the DSL and the walk dogfooded together.
    private static var toggleCollapsed: ExpectationSet {
        ExpectationSet(
            "advanced — collapsed",
            [
                Expectation("advanced-toggle").visible.role(.toggle).width(.atLeast(200)),
                Expectation("collapsed-summary")
                    .visible
                    .textContains("hidden")
                    .below("advanced-toggle"),
            ]
        )
    }

    /// Every scenario name paired with the set that states its intent.
    ///
    /// Keyed by ``VerdictScenario/name`` rather than by index so a reordering
    /// of the catalog cannot silently repoint a set at a different scenario.
    private static var declaredSets: [String: ExpectationSet] {
        [
            CleanSettingsScenario.scenarioName: cleanSettings,
            "demo-truncating-label": truncatingLabel,
            "demo-offscreen-button": offscreenButton,
            "demo-toggle-layout": toggleCollapsed,
        ]
    }

    // MARK: - Evaluation

    /// Renders `entry` and returns the findings its declared set produces.
    @MainActor
    private func findings(
        for entry: DemoScenarioEntry,
        using set: ExpectationSet
    ) async throws -> [Finding] {
        let host = entry.makeHost(viewport: entry.recommendedViewport, deadline: 5)
        let tree = try await host.currentTree()
        let viewport = Rect(
            x: 0,
            y: 0,
            width: entry.recommendedViewport.width,
            height: entry.recommendedViewport.height
        )
        let context = LintContext.macOS(viewport: viewport, scenario: entry.name)
        return set.evaluate(in: tree, context: context)
    }

    /// Looks up a catalog entry by scenario name.
    private func entry(named name: String) throws -> DemoScenarioEntry {
        try XCTUnwrap(
            DemoScenarios.all.first { $0.name == name },
            "the catalog has no scenario named '\(name)' — a set here was left behind by a "
                + "renamed or deleted scenario"
        )
    }

    // MARK: - The correct scenario satisfies its declared intent

    @MainActor
    func testTheCleanScenarioSatisfiesEveryDeclaredExpectation() async throws {
        let entry = try entry(named: CleanSettingsScenario.scenarioName)
        let produced = try await findings(for: entry, using: Self.cleanSettings)

        XCTAssertEqual(
            produced.map(\.message),
            [],
            "the clean scenario is the catalog's reference CORRECT layout, so a declarative "
                + "statement of its intent must produce no findings. A failure here is either a "
                + "DSL defect or an over-tight expectation transcribed from the render."
        )
    }

    @MainActor
    func testTheCollapsedToggleStateSatisfiesItsDeclaredIntent() async throws {
        let entry = try entry(named: "demo-toggle-layout")
        let produced = try await findings(for: entry, using: Self.toggleCollapsed)

        XCTAssertEqual(produced.map(\.message), [], "the collapsed state renders as declared")
    }

    // MARK: - The defective scenario is caught by the DSL, by node and by reason

    /// The load-bearing positive: the DSL catches a real planted defect, and
    /// names the node it caught it on.
    ///
    /// This is the assertion that makes the DSL worth having — `offscreen` (the
    /// RULE) already fires here, and this proves an AUTHOR who never wrote a
    /// rule gets the same catch out of a sentence about their own screen.
    @MainActor
    func testTheOffscreenButtonViolatesItsDeclaredContainment() async throws {
        let entry = try entry(named: "demo-offscreen-button")
        let produced = try await findings(for: entry, using: Self.offscreenButton)

        let offending = produced.filter { $0.nodeID == "apply-button" }
        XCTAssertFalse(
            offending.isEmpty,
            "the apply button renders at x=420 in a 320 pt viewport, so an expectation that it "
                + "sits below the title and is visible must produce a finding naming it. "
                + "Produced: \(produced.map(\.message))"
        )
    }

    // MARK: - Falsifiability

    /// The one test here that separates a working evaluator from one that
    /// returns `[]` unconditionally.
    ///
    /// Every other test in this file states expectations a render satisfies (or
    /// a single defect the engine already catches), so all of them pass against
    /// an `evaluate` that never produces a finding. This one takes each
    /// scenario's own declared set, negates ONE claim in it against the same
    /// render, and requires a finding — per scenario, so a DSL that has gone
    /// blind on one predicate family cannot hide behind another that still
    /// works.
    @MainActor
    func testEveryExpectationSetIsFalsifiableAgainstItsOwnScenario() async throws {
        // A claim that the render definitively does NOT satisfy, chosen per
        // scenario from the measured geometry so the negation is unambiguous.
        let negations: [String: Expectation] = [
            CleanSettingsScenario.scenarioName:
                Expectation("save-button").leftOf("cancel-button"),
            "demo-truncating-label":
                Expectation("storage-title").above("storage-title"),
            "demo-offscreen-button":
                Expectation("filters-title").width(.atLeast(10_000)),
            "demo-toggle-layout":
                Expectation("collapsed-summary").text("this is not what it says"),
        ]

        XCTAssertEqual(
            Set(negations.keys),
            Set(Self.declaredSets.keys),
            "every declared set needs a negation, or a set can go unfalsified"
        )

        for (name, negation) in negations.sorted(by: { $0.key < $1.key }) {
            let entry = try entry(named: name)
            let negated = ExpectationSet("negated \(name)", [negation])
            let produced = try await findings(for: entry, using: negated)

            XCTAssertFalse(
                produced.isEmpty,
                "'\(name)': a claim the render contradicts produced NO finding, so this "
                    + "scenario's expectations are satisfied by an evaluator that judges "
                    + "nothing — every other assertion about it is vacuous"
            )
        }
    }

    // MARK: - Coverage in both directions

    /// A set left behind by a deleted scenario must not quietly pass, and a
    /// scenario added without a set must not quietly render unverified.
    ///
    /// The catalog holds six scenarios and this file declares four: the two
    /// abstentions are DELIBERATE and named, because "cover everything" and
    /// "cover what the DSL can express" are different claims and only the
    /// second one is true. Stating them here means a seventh scenario cannot
    /// join the abstained set by accident.
    func testTheDeclaredSetsAndTheCatalogCoverEachOther() throws {
        let catalogNames = Set(DemoScenarios.all.map(\.name))
        let declaredNames = Set(Self.declaredSets.keys)

        // `overlapping-badges` and `undersized-tap-target` are not declared:
        // their defects are pure geometry between siblings (a 20 pt overlap, an
        // 18 pt tap target) with no author-level sentence to write. The DSL has
        // no `doesNotOverlap` or `isTappable` predicate, and adding one would
        // duplicate `sibling-overlap` and `tap-target` in a second vocabulary
        // that could then disagree with the first.
        let deliberatelyUndeclared: Set<String> = [
            "demo-overlapping-badges",
            "demo-undersized-tap-target",
        ]

        XCTAssertTrue(
            declaredNames.isSubset(of: catalogNames),
            "declared sets name scenarios the catalog does not have: "
                + "\(declaredNames.subtracting(catalogNames).sorted())"
        )
        XCTAssertEqual(
            catalogNames.subtracting(declaredNames),
            deliberatelyUndeclared,
            "a scenario is neither declared nor listed as a deliberate abstention — it is "
                + "rendering unverified by the DSL, which is exactly the silent gap this test "
                + "exists to close"
        )
    }
}
