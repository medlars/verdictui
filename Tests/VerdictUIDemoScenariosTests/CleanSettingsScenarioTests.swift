import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// The false-positive guard, asserted in the wave that plants the defects rather
/// than in the wave that catches them.
///
/// Everything else in this catalog proves a rule can fire. Nothing else proves a
/// rule can stay quiet, and a lint library that cries wolf on an ordinary layout
/// is one people switch off — at which point the five scenarios that do fire
/// stop mattering. So this assertion cannot wait for Task 6.
final class CleanSettingsScenarioTests: XCTestCase {
    /// See ``DemoScenarioRenderingTests/invokeTest()``: without draining the
    /// pool the hosted AppKit hierarchies accumulate and wedge the suite.
    override func invokeTest() { autoreleasepool { super.invokeTest() } }

    @MainActor
    func testCleanSettingsProducesNoFindingsAtAll() async throws {
        let tree = try await Self.tree()
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: CleanSettingsScenario.scenarioName)
        )

        // Rendered into the failure message rather than counted, because
        // "expected 0, got 2" sends the reader back to the debugger while the
        // rule, the node and the measurement that fired name the fix outright.
        XCTAssertEqual(
            verdict.findings.map(\.rule),
            [],
            "the false-positive guard fired: "
                + verdict.findings.map { "\($0.rule) on \($0.nodeID): \($0.message)" }
                .joined(separator: "; ")
        )
        XCTAssertEqual(verdict.status, .pass)
    }

    /// The guard is only worth having if the layout it exonerates is one the
    /// rules could plausibly convict.
    ///
    /// ``SiblingOverlapRule`` is the rule most likely to produce a false
    /// positive here, and it is silenced by a *declaration*, not by an absence:
    /// the card and the pill really do intersect, and the finding is withheld
    /// only because their parent's role identifier says the layering is
    /// deliberate. If a later edit pulled the pill off the card, the
    /// zero-findings test above would keep passing while having stopped
    /// exercising anything — so the overlap itself is asserted.
    @MainActor
    func testTheExoneratedOverlapIsReal() async throws {
        let tree = try await Self.tree()

        let layer = try XCTUnwrap(tree.node(withID: "card-layer"), "the layering container is gone")
        XCTAssertEqual(
            layer.role.identifier,
            "zstack",
            "the container no longer declares layering, so the overlap below is unexplained"
        )

        let card = try XCTUnwrap(tree.node(withID: "card-surface"))
        let pill = try XCTUnwrap(tree.node(withID: "card-pill"))
        let overlap = try XCTUnwrap(
            card.frame.intersection(pill.frame),
            "the card and the pill no longer overlap, so this scenario stopped testing the "
                + "sibling-overlap negative path"
        )
        XCTAssertGreaterThan(overlap.width, 0)
        XCTAssertGreaterThan(overlap.height, 0)

        // Overlapping is not enough: the rule only considers *siblings*, so a
        // pill that had become a child of the card would also be silent, for a
        // reason that has nothing to do with the declared layering.
        let siblings = Set(layer.children.map(\.id))
        XCTAssertEqual(
            siblings,
            ["card-surface", "card-pill"],
            "the overlapping pair are no longer siblings under the layering container"
        )
    }

    /// The same geometry without the declaration is a finding — the proof that
    /// the exemption above is doing the work, and that the rule is not simply
    /// blind to this shape.
    @MainActor
    func testTheSameOverlapWithoutADeclarationWouldFire() async throws {
        let tree = try await Self.tree()
        let layer = try XCTUnwrap(tree.node(withID: "card-layer"))

        var undeclared = layer
        undeclared.role = .container

        let findings = SiblingOverlapRule().evaluate(
            undeclared,
            context: .macOS(viewport: tree.frame, scenario: CleanSettingsScenario.scenarioName)
        )

        XCTAssertEqual(
            findings.map(\.rule),
            ["sibling-overlap"],
            "relabelling the layering container as a plain container did not produce the "
                + "finding the declaration is suppressing, so the clean scenario is clean for "
                + "some other reason than the one it documents"
        )
        XCTAssertEqual(findings.first?.nodeID, "card-pill")
    }

    @MainActor
    private static func tree() async throws -> SemanticNode {
        let entry = try XCTUnwrap(
            DemoScenarios.entry(named: CleanSettingsScenario.scenarioName),
            "the clean scenario left the catalog"
        )
        return try await entry.makeHost().currentTree()
    }
}
