// The dogfood proper: verifying a SagaMail screen with VerdictUI, from OUTSIDE
// the engine's own package.
//
// The expectations live HERE, in the consumer's test target, never in the
// module under test. `DemoScenarios.swift` settled that in Wave 2 and the
// reasoning transfers unchanged: an assertion written against a rule id
// supplied by the very module under test would pass whatever that module
// claimed.
import SwiftUI
import VerdictUIKernel
import VerdictUIMacroSupport
import VerdictUIProbe
import XCTest

@testable import SagaMailDogfood

/// The screen as a scenario — the shape `OracleHost` renders and the CLI names.
///
/// `verdictProbing(_:)` is what routes a `@Verifiable` view's PROBED content
/// into the scenario; handing it the bare view would render the unprobed body
/// and produce a tree with no probed node at all (ADR 2026-009).
private struct NotificationsScenario: VerdictScenario {
    let name: String
    let showAdvanced: Bool

    @MainActor @ViewBuilder
    func body(state: ScenarioState) -> some View {
        verdictProbing(NotificationsSettingsScreen(showAdvanced: showAdvanced))
    }
}

/// Renders the adopted screen and returns its semantic tree.
@MainActor
private func renderScreen(
    showAdvanced: Bool,
    name: String = "sagamail-notifications",
    width: Double = 420,
    height: Double = 400
) async throws -> SemanticNode {
    let host = OracleHost(
        scenario: NotificationsScenario(name: name, showAdvanced: showAdvanced),
        viewport: Size(width: width, height: height)
    )
    return try await host.currentTree()
}

/// Produces a verdict exactly as `verdictui verify` does.
@MainActor
private func verdict(for tree: SemanticNode, scenario: String) -> Verdict {
    RuleEngine.run(
        rules: RuleEngine.standardRules,
        on: tree,
        context: .macOS(viewport: tree.frame, scenario: scenario)
    )
}

@MainActor
final class NotificationsSettingsVerdictTests: XCTestCase {
    /// Drains the autorelease pool around every test, as the engine's own
    /// hosting tests do — `swift test` has no run loop to pump it between
    /// tests and the `NSHostingView` hierarchies would accumulate.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: The adoption claim

    /// One `@Verifiable` line is supposed to make a real screen observable.
    /// This is the test that would fail if that claim were false — and it is
    /// the `vacuous-verdict` shape from Wave 4: a tree with no probed node at
    /// all still renders, so PASS is meaningless without this check.
    func testTheAdoptedScreenProducesAProbedTree() async throws {
        let tree = try await renderScreen(showAdvanced: false)
        // The macro derives ids as `TypeName.role.index`, so a node named for
        // this screen is proof the adopted view's probed content is what
        // rendered — not merely that something rendered.
        let ids = tree.flattened().map(\.id)
        let own = ids.filter { $0.hasPrefix("NotificationsSettingsScreen.") }

        XCTAssertFalse(
            own.isEmpty,
            "@Verifiable produced no probed nodes — the adoption is decorative: \(ids)"
        )
        XCTAssertGreaterThanOrEqual(
            Set(own).count, 3,
            "expected several independently-cited elements, got \(own.sorted())"
        )
    }

    /// Conditional content is the shape Wave 4 Task 4 found ENTIRELY unprobed
    /// (an `if` inside a `@ViewBuilder` is a statement, not an expression), and
    /// it is the shape this SagaMail screen leans on hardest. A dogfood that
    /// only rendered the default state would never touch it.
    func testConditionalContentIsProbedWhenItAppears() async throws {
        let collapsed = try await renderScreen(showAdvanced: false).flattened()
        let expanded = try await renderScreen(
            showAdvanced: true, name: "sagamail-notifications-advanced"
        ).flattened()

        XCTAssertGreaterThan(
            expanded.count, collapsed.count,
            "the advanced section added no nodes — conditional content is unprobed"
        )
    }

    // MARK: The verdict

    /// The screen as SagaMail ships it is CLEAN. This is the assertion a
    /// SagaMail developer would actually keep in CI.
    ///
    /// It asserted merely "no findings other than tap-target" until 2026-08-14,
    /// because all three `Toggle`s tripped a 28 pt minimum no standard macOS
    /// control can reach — the rule was miscalibrated, not the screen. With the
    /// floor corrected to 12 pt (the measured size of a `.controlSize(.mini)`
    /// switch) the exemption is gone and the stronger claim holds.
    func testTheDefaultScreenPassesEveryStandardRule() async throws {
        let tree = try await renderScreen(showAdvanced: false)
        let result = verdict(for: tree, scenario: "sagamail-notifications")

        XCTAssertEqual(
            result.status, .pass,
            "unexpected findings: \(result.findings.map { "\($0.rule) on \($0.nodeID ?? "-")" })"
        )
    }

    /// The expanded state too — the long "Morning & Evening (9 AM / 6 PM)"
    /// label is exactly the kind of string that truncates in a narrow settings
    /// pane, which is why this screen was chosen for the dogfood. Nothing
    /// truncates at 420 pt, so the verdict must be clean here as well.
    func testTheExpandedScreenPassesEveryStandardRule() async throws {
        let tree = try await renderScreen(
            showAdvanced: true, name: "sagamail-notifications-advanced"
        )
        let result = verdict(for: tree, scenario: "sagamail-notifications-advanced")

        XCTAssertEqual(
            result.status, .pass,
            "the advanced section introduced findings: "
                + "\(result.findings.map { "\($0.rule) on \($0.nodeID ?? "-")" })"
        )
    }

    // MARK: The control

    /// Without this, every assertion above is satisfied by an engine that
    /// reports PASS unconditionally. Squeezing the viewport to a width no
    /// settings pane would use must produce findings — if it does not, the
    /// PASSes above prove nothing about the screen.
    func testTheEngineCanStillFailThisScreen() async throws {
        let tree = try await renderScreen(
            showAdvanced: true, name: "sagamail-notifications-cramped",
            width: 90, height: 120
        )
        let result = verdict(for: tree, scenario: "sagamail-notifications-cramped")

        XCTAssertEqual(
            result.status, .fail,
            "a 90pt-wide settings pane produced no findings — the PASSes above are vacuous"
        )
        // Evidence, not a boolean: each error must name the element, or a
        // developer cannot act on it.
        for finding in result.findings where finding.severity == .error {
            XCTAssertNotNil(
                finding.nodeID,
                "finding '\(finding.rule)' cites no node — unusable to a developer"
            )
        }
    }
}
