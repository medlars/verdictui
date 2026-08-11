import SwiftUI
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
