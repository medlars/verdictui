import SwiftUI
import VerdictUIDemoScenarios
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIProbe

/// Sweeps render one scenario across a variant matrix — the channel that turns
/// "the German string truncates at accessibility text sizes" from a support
/// ticket into a table cell.
///
/// The load-bearing assertion is ``testVariantsActuallyChangeTheRenderedTree``.
/// `OracleHost` PINS locale, colour scheme, dynamic type and layout direction so
/// a machine's own settings cannot change a verdict; a sweep needs to vary
/// exactly those axes, so the override must be applied outside the pin. Get the
/// order wrong and every cell renders the baseline while reporting a different
/// name — a sweep that runs, reports, and measures one thing N times. That
/// failure is completely silent, so a test that only checked "N cells came back"
/// would pass against it.
final class SweepTests: XCTestCase {

    // MARK: - The wave's timing budget

    /// The exit gate's matrix, spelled once: 3 locales × 2 type sizes × 2
    /// colour schemes = 12 cells.
    private static var gateVariants: [Variant] {
        Sweep<CleanSettingsScenario>.matrix(
            locales: ["en_US", "de_DE", "ar_SA"],
            colorSchemes: [.light, .dark],
            dynamicTypeSizes: [.medium, .accessibility3]
        )
    }

    /// Wall-clock ceiling for the gate matrix, in milliseconds.
    ///
    /// The plan's exit gate names 5 s, and that number is kept rather than
    /// tightened to the measurement. Five consecutive runs of the real matrix
    /// measured **208.8 / 112.2 / 122.7 / 130.6 / 133.4 ms** — roughly 25×
    /// under budget — and a gate re-cut to, say, 250 ms would fail for a busy
    /// neighbour rather than for a regression, which is precisely the defect
    /// `no.md` #13 records about the p95 gate that blocked a PM at 105 ms on a
    /// 49 ms median. The published budget is a PRODUCT commitment; the headroom
    /// is reported in the failure message so a real regression is legible as
    /// one even while it passes.
    private static let gateBudgetMs: Double = 5_000

    /// The whole gate matrix renders inside the published budget.
    ///
    /// ### Why the first run is included rather than discarded
    ///
    /// Run 1 measured 208.8 ms against a 112–133 ms steady state — SwiftUI and
    /// AppKit warm caches on first host construction. A benchmark would drop it
    /// as noise. This is not a benchmark: it is the claim a user experiences,
    /// and the first sweep of a session is the one they wait for. Discarding it
    /// would measure a state the product is rarely in.
    ///
    /// ### Why this asserts on every lane
    ///
    /// Unlike SLO 1's p50 (`no.md` #15), this budget is not lane-split. The
    /// margin is ~25×, so even the constrained hosts that span 62% on the
    /// harness benchmark cannot cross it without something being genuinely
    /// broken — and a test that would only fail on a real defect is exactly the
    /// one that should keep asserting everywhere. The measured elapsed time is
    /// printed either way, so a shared runner still contributes a reading.
    @MainActor
    func testTheGateMatrixRendersInsideItsBudget() async throws {
        let variants = Self.gateVariants
        XCTAssertEqual(
            variants.count,
            12,
            "the exit gate names 3 locales × 2 type sizes × 2 schemes; a matrix that is not 12 "
                + "cells is not the matrix the budget was measured against"
        )

        let sweep = Sweep(scenario: CleanSettingsScenario(), variants: variants)
        let started = ContinuousClock.now
        let report = await sweep.run()
        let elapsedMs = Self.milliseconds(since: started)

        print("SWEEP-BUDGET cells=\(report.cells.count) elapsedMs=\(elapsedMs)")

        // A sweep that failed to render every cell would finish fast and look
        // excellent, so the count and the errors are asserted BEFORE the clock.
        // Time is only meaningful for a run that did the work.
        XCTAssertEqual(
            report.cells.count,
            variants.count,
            "the sweep returned \(report.cells.count) cells for \(variants.count) variants — a "
                + "timing figure for a partial matrix measures nothing"
        )
        let unmeasured = report.cells.filter { $0.verdict == nil }
        XCTAssertTrue(
            unmeasured.isEmpty,
            "\(unmeasured.count) cell(s) produced no verdict, so this run was faster than a "
                + "real one by exactly the work it skipped: "
                + "\(unmeasured.map { "\($0.variant.name): \($0.error ?? "no error recorded")" })"
        )

        XCTAssertLessThan(
            elapsedMs,
            Self.gateBudgetMs,
            "the \(variants.count)-cell gate matrix took \(elapsedMs) ms against a "
                + "\(Self.gateBudgetMs) ms budget. Five reference runs on developer hardware "
                + "measured 208.8/112.2/122.7/130.6/133.4 ms, so this is roughly "
                + "\(Int(elapsedMs / 133.0))× the steady-state figure — look for a per-cell "
                + "host that stopped being reused or a settle that started timing out"
        )
    }

    /// Milliseconds elapsed since `start`, from a monotonic clock.
    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let components = elapsed.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    /// A scenario whose layout is a visible function of the environment.
    ///
    /// Keyed on ``LayoutDirection`` rather than dynamic type, and that choice
    /// was measured rather than assumed: on macOS `dynamicTypeSize` is DELIVERED
    /// but INERT — a reader inside the host prints `accessibility5` while `Text`
    /// renders byte-identically at both sizes. A "does the variant reach the
    /// view?" test written on an inert axis can never pass, and would have sent
    /// me rewriting a working host. Mirroring moves `x` from 0 to 204, which is
    /// unmistakable.
    private struct DirectionSensitiveScenario: VerdictScenario, Sendable {
        var name: String { "direction-sensitive" }

        @MainActor func body(state: ScenarioState) -> some View {
            HStack {
                Text("Internationalization")
                    .verdictProbe("label", role: .text)
                Spacer()
            }
            .frame(width: 320, height: 200)
        }
    }

    /// Renders nothing that depends on the environment — the control for the
    /// determinism assertion.
    /// Renders nothing that depends on the environment — the control for the
    /// determinism assertion.
    ///
    /// A `Text` rather than a `Color.clear`: the first draft probed a
    /// `Color.clear.frame(...)` and produced `vacuous-verdict`, because the
    /// probe reported no measurable content and the kernel correctly refused to
    /// call an unobserved tree clean. The guard was right and the fixture was
    /// wrong — exactly the shape this engine exists to catch, caught in its own
    /// test suite.
    private struct FixedScenario: VerdictScenario, Sendable {
        var name: String { "fixed" }

        @MainActor func body(state: ScenarioState) -> some View {
            VStack {
                Text("Fixed")
                    .verdictProbe("box", role: .text)
            }
            .frame(width: 320, height: 200)
        }
    }

    // MARK: - The matrix

    func testTheMatrixIsTheCartesianProductOfItsAxes() {
        let variants = Sweep<FixedScenario>.matrix(
            locales: ["en_US", "de_DE"],
            colorSchemes: [.light, .dark],
            dynamicTypeSizes: [.medium, .accessibility3]
        )

        XCTAssertEqual(variants.count, 8)
        XCTAssertEqual(Set(variants.map(\.name)).count, 8, "every cell must be distinctly named")
    }

    /// An empty axis must contribute its baseline value, not annihilate the
    /// product. Without this, a caller who varies only locales gets a sweep that
    /// renders nothing and reports clean — the worst possible answer.
    func testAnEmptyAxisContributesItsBaselineRatherThanEmptyingTheMatrix() {
        let variants = Sweep<FixedScenario>.matrix(locales: ["en_US", "de_DE"])

        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants.allSatisfy { $0.dynamicTypeSize == .medium })
        XCTAssertTrue(variants.allSatisfy { $0.colorScheme == .light })
    }

    func testAMatrixWithNoAxesAtAllIsTheSingleBaselineCell() {
        let variants = Sweep<FixedScenario>.matrix()

        XCTAssertEqual(variants, [Variant.baseline])
    }

    /// The name is built from every axis, including defaults: a name that omits
    /// them changes meaning when a default changes, and a sweep report is read
    /// months after it was produced.
    func testACellNameCarriesEveryAxis() {
        let variant = Variant(
            localeIdentifier: "de_DE",
            colorScheme: .dark,
            dynamicTypeSize: .accessibility3,
            layoutDirection: .rightToLeft,
            viewport: Size(width: 320, height: 200)
        )

        XCTAssertEqual(variant.name, "de_DE/dark/ax3/rtl/320x200")
    }

    // MARK: - Variants must actually reach the render

    /// The assertion this whole file exists for.
    ///
    /// If `verdictVariant` were applied INSIDE the host's pins, the pin would
    /// overwrite it and every cell would render identically. Measuring the
    /// rendered geometry is the only way to tell the two apart — a cell count or
    /// a cell name would agree with both.
    @MainActor
    func testVariantsActuallyChangeTheRenderedTree() async throws {
        let report = await Sweep(
            scenario: DirectionSensitiveScenario(),
            variants: Sweep<DirectionSensitiveScenario>.matrix(
                layoutDirections: [.leftToRight, .rightToLeft]
            )
        ).run(includeTrees: true)

        XCTAssertEqual(report.cells.count, 2)
        // The mirrored cell moves the label's ORIGIN, not its width — the text
        // is the same text. Asserting on width would fail against a working
        // host, which is how the first draft of this test read as a bug in the
        // engine rather than in itself.
        let origins = try report.cells.map { cell -> Double in
            let verdict = try XCTUnwrap(cell.verdict, "cell \(cell.variant.name) did not render")
            let tree = try XCTUnwrap(verdict.tree ?? nil)
            return try XCTUnwrap(tree.node(withID: "label")).frame.x
        }

        XCTAssertNotEqual(
            origins[0],
            origins[1],
            "both cells rendered the same geometry, so the variant never reached the view — "
                + "applyingVariant must sit CLOSER TO THE CONTENT than "
                + "verdictPinnedEnvironment(), and the pin must stand down on the axes a "
                + "variant owns"
        )
    }

    /// The control for the assertion above: a scenario that does NOT depend on
    /// the environment must render identically across variants. Without it,
    /// "the widths differ" could be satisfied by a host that is simply
    /// nondeterministic.
    @MainActor
    func testAnEnvironmentIndependentScenarioRendersIdenticallyAcrossVariants() async throws {
        let report = await Sweep(
            scenario: FixedScenario(),
            variants: Sweep<FixedScenario>.matrix(
                layoutDirections: [.leftToRight, .rightToLeft]
            )
        ).run(includeTrees: true)

        let frames = try report.cells.map { cell -> Rect in
            let verdict = try XCTUnwrap(cell.verdict)
            let tree = try XCTUnwrap(verdict.tree ?? nil)
            return try XCTUnwrap(tree.node(withID: "box")).frame
        }

        XCTAssertEqual(frames[0], frames[1], "the host is not deterministic across cells")
    }

    // MARK: - Reporting

    @MainActor
    func testACleanSweepIsCleanAndSaysSo() async {
        let report = await Sweep(
            scenario: FixedScenario(),
            variants: [Variant.baseline]
        ).run()

        XCTAssertTrue(report.isClean, "got: \(report.cells.compactMap(\.verdict?.findings))")
        XCTAssertTrue(report.failingCells.isEmpty)
        XCTAssertTrue(report.unmeasuredCells.isEmpty)
        XCTAssertEqual(report.scenario, "fixed")
        XCTAssertTrue(report.markdownGrid().contains("are clean"))
    }

    /// An unmeasured cell — one whose host could not render at all — must make
    /// the sweep not-clean. "We could not look" and "we looked and it was fine"
    /// are opposite answers, and collapsing them is the false-green this product
    /// exists to prevent.
    func testAnUnmeasuredCellIsNeitherAPassNorAFailButBlocksClean() {
        let unmeasured = SweepCell(
            variant: .baseline,
            verdict: nil,
            error: "host could not settle"
        )
        let report = SweepReport(scenario: "x", cells: [unmeasured])

        XCTAssertFalse(report.passed(at: 0))
        XCTAssertTrue(report.failingCells.isEmpty, "an unrendered cell is not a FAILING cell")
        XCTAssertEqual(report.unmeasuredCells.count, 1)
        XCTAssertFalse(report.isClean, "a sweep with an unmeasured cell must not read as clean")
    }

    /// The grid is the deliverable — a rule × variant table an author reads at a
    /// glance. An unmeasured cell must be visibly distinct from a clean one.
    func testTheGridDistinguishesFindingsFromCleanAndFromUnmeasured() {
        let failing = SweepCell(
            variant: Variant(localeIdentifier: "de_DE"),
            verdict: Verdict(
                scenario: "x",
                findings: [
                    Finding(
                        rule: "truncation",
                        severity: .error,
                        nodeID: "label",
                        message: "m",
                        suggestion: nil
                    )
                ]
            ),
            error: nil
        )
        let clean = SweepCell(
            variant: .baseline,
            verdict: Verdict(scenario: "x", findings: []),
            error: nil
        )
        let unmeasured = SweepCell(
            variant: Variant(localeIdentifier: "fr_FR"),
            verdict: nil,
            error: "boom"
        )

        let grid = SweepReport(scenario: "x", cells: [clean, failing, unmeasured]).markdownGrid()

        XCTAssertTrue(grid.contains("`truncation`"), grid)
        XCTAssertTrue(grid.contains("·"), "a clean cell must read as clean: \(grid)")
        XCTAssertTrue(grid.contains("?"), "an unmeasured cell must read as unknown: \(grid)")
    }
}

extension SweepReport {
    /// Test helper: whether the cell at `index` passed.
    fileprivate func passed(at index: Int) -> Bool { cells[index].passed }
}
