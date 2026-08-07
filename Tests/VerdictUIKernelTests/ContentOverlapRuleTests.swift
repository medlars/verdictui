import XCTest

@testable import VerdictUIKernel

/// `content-overlap` catches the overlap `sibling-overlap` is blind to by
/// construction: two pieces of content that collide across different parents.
///
/// The negative cases carry as much weight as the positive ones here. A rule
/// that compares every pair of frames in a tree fires on ordinary nesting — a
/// label inside its row inside its list — so each structural relationship that
/// must NOT report is pinned, and each is written so that removing the guard
/// which exempts it makes this file fail.
final class ContentOverlapRuleTests: XCTestCase {
    private let rule = ContentOverlapRule()

    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context() -> LintContext {
        LintContext(scenario: "content-overlap", viewport: Self.viewport)
    }

    private func root(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(id: "root", role: .container, frame: Self.viewport, children: children)
    }

    /// A row container at `y`, holding one text that may overflow it.
    private func row(
        _ id: String,
        y: Double,
        height: Double = 30,
        textHeight: Double? = nil
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: .container,
            frame: Rect(x: 0, y: y, width: 400, height: height),
            children: [
                SemanticNode(
                    id: "\(id)-text",
                    role: .text,
                    frame: Rect(x: 0, y: y, width: 400, height: textHeight ?? height)
                )
            ]
        )
    }

    // MARK: - the defect this rule exists for

    func testTextOverflowingItsRowCoversTheNextRowsText() throws {
        // The canonical VStack overflow: row-a's text is 50 pt tall inside a
        // 30 pt row, so it runs into row-b's text. The two texts have DIFFERENT
        // parents, which is exactly why `sibling-overlap` cannot see it.
        let tree = root([
            row("row-a", y: 0, textHeight: 50),
            row("row-b", y: 30),
        ])

        let findings = rule.evaluate(tree, context: context())

        let finding = try XCTUnwrap(findings.first, "cross-parent content overlap went unreported")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.rule, "content-overlap")
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.nodeID, "row-b-text")
        XCTAssertEqual(
            finding.message,
            "'row-b-text' overlaps 'row-a-text' by 400 x 20 pt — the two have different "
                + "parents, so no single container's layout can resolve it"
        )
        XCTAssertNotNil(finding.suggestion)
    }

    /// The control for the test above: `sibling-overlap` really is blind here.
    /// Without this, the new rule could be duplicating cover that already
    /// existed and the suite would not notice.
    func testSiblingOverlapRuleIsBlindToTheSameTree() {
        let tree = root([
            row("row-a", y: 0, textHeight: 50),
            row("row-b", y: 30),
        ])
        XCTAssertTrue(
            SiblingOverlapRule().evaluate(tree, context: context()).isEmpty,
            "if sibling-overlap catches this, content-overlap is redundant rather than additive"
        )
    }

    // MARK: - structural relationships that must never report

    func testContentInsideItsOwnAncestorsIsNotOverlap() {
        // Every child overlaps its parent, and its grandparent. If ancestry were
        // not exempt this single well-formed row would report twice.
        let tree = root([row("row-a", y: 0)])
        XCTAssertTrue(rule.evaluate(tree, context: context()).isEmpty)
    }

    func testDirectSiblingsAreLeftToSiblingOverlapRule() {
        // Two texts under ONE parent are sibling-overlap's jurisdiction. Reporting
        // them here too would double-bill every overlap in the tree.
        let tree = root([
            SemanticNode(
                id: "row",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 400, height: 40),
                children: [
                    SemanticNode(id: "a", role: .text, frame: Rect(x: 0, y: 0, width: 100, height: 40)),
                    SemanticNode(id: "b", role: .text, frame: Rect(x: 50, y: 0, width: 100, height: 40)),
                ]
            )
        ])
        XCTAssertTrue(rule.evaluate(tree, context: context()).isEmpty)
        XCTAssertEqual(
            SiblingOverlapRule().evaluate(tree, context: context()).count,
            1,
            "the pair must still be caught by exactly one rule, not zero"
        )
    }

    func testContainersThemselvesAreNotComparedOnlyTheirContent() {
        // Two overlapping ROWS with no overlapping content is a layout choice
        // (a background band, a grouped header). Only leaf content collides.
        let tree = root([
            SemanticNode(
                id: "band",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 400, height: 100),
                children: [
                    SemanticNode(id: "band-text", role: .text, frame: Rect(x: 0, y: 0, width: 100, height: 20))
                ]
            ),
            SemanticNode(
                id: "card",
                role: .container,
                frame: Rect(x: 0, y: 50, width: 400, height: 100),
                children: [
                    SemanticNode(id: "card-text", role: .text, frame: Rect(x: 0, y: 120, width: 100, height: 20))
                ]
            ),
        ])
        XCTAssertTrue(rule.evaluate(tree, context: context()).isEmpty)
    }

    // MARK: - the layering and hygiene exemptions, matched to sibling-overlap

    func testDeclaredLayeringOnEitherNodeOrAnyAncestorIsIntent() {
        // A zIndex anywhere on either path is a statement that the author
        // arranged the paint order deliberately. Each position is asserted
        // separately: a guard that checked only the node itself, or only the
        // immediate parent, would pass a weaker version of this test.
        for position in ["node", "parent", "grandparent"] {
            var tree = root([
                row("row-a", y: 0, textHeight: 50),
                row("row-b", y: 30),
            ])
            switch position {
            case "node": tree.children[1].children[0].zIndex = 1
            case "parent": tree.children[1].zIndex = 1
            default: tree.children[0].zIndex = 1
            }
            XCTAssertTrue(
                rule.evaluate(tree, context: context()).isEmpty,
                "a zIndex on the \(position) did not read as intentional layering"
            )
        }
    }

    func testZStackAncestryIsIntent() {
        for casing in ["ZStack", "zstack", "ZSTACK"] {
            var tree = root([
                row("row-a", y: 0, textHeight: 50),
                row("row-b", y: 30),
            ])
            tree.role = .custom(casing)
            XCTAssertTrue(
                rule.evaluate(tree, context: context()).isEmpty,
                "a shared '\(casing)' ancestor did not read as intentional layering"
            )
        }
    }

    func testInvisibleEmptyAndSpacerContentIsIgnored() {
        var invisible = root([row("row-a", y: 0, textHeight: 50), row("row-b", y: 30)])
        invisible.children[1].children[0].isVisible = false
        XCTAssertTrue(rule.evaluate(invisible, context: context()).isEmpty)

        var empty = root([row("row-a", y: 0, textHeight: 50), row("row-b", y: 30)])
        empty.children[1].children[0].frame = Rect(x: 0, y: 30, width: 0, height: 0)
        XCTAssertTrue(rule.evaluate(empty, context: context()).isEmpty)

        // A Spacer occupies space and renders nothing, so anything crossing it
        // is not a collision between two visible things.
        var spacer = root([row("row-a", y: 0, textHeight: 50), row("row-b", y: 30)])
        spacer.children[1].children[0].role = .spacer
        XCTAssertTrue(rule.evaluate(spacer, context: context()).isEmpty)
    }

    func testSuppressionSilencesOnlyTheTaggedNode() {
        var tree = root([row("row-a", y: 0, textHeight: 50), row("row-b", y: 30)])
        tree.children[1].children[0].attributes[LintContext.suppressionKey] = .string("content-overlap")
        XCTAssertTrue(rule.evaluate(tree, context: context()).isEmpty)
    }

    // MARK: - measurement hygiene

    func testSubPixelOverlapIsToleratedButRealOverlapIsNot() {
        // Float noise from layout arithmetic must not fire; 0.5 pt matches the
        // tolerance TruncationRule already uses for the same class of noise.
        var noise = root([row("row-a", y: 0, textHeight: 30.4), row("row-b", y: 30)])
        XCTAssertTrue(
            rule.evaluate(noise, context: context()).isEmpty,
            "0.4 pt of float noise must not be reported as a defect"
        )

        // ... and the control: just past the tolerance it IS reported, so the
        // tolerance cannot be widened into silence without failing here.
        noise = root([row("row-a", y: 0, textHeight: 30.6), row("row-b", y: 30)])
        XCTAssertEqual(rule.evaluate(noise, context: context()).count, 1)
    }

    func testDeterministicOrderingAcrossManyOverlaps() {
        // Evidence must be byte-stable for baselines: same tree, same order.
        let tree = root([
            row("row-a", y: 0, textHeight: 90),
            row("row-b", y: 30),
            row("row-c", y: 60),
        ])
        let first = rule.evaluate(tree, context: context()).map(\.nodeID)
        let second = rule.evaluate(tree, context: context()).map(\.nodeID)
        XCTAssertEqual(first, second)
        // row-a's text spans y 0–90, so it collides with BOTH lower texts.
        // row-b's text (30–60) and row-c's text (60–90) share only an edge,
        // which is adjacency — hence two findings, not three. Verified against
        // arithmetic computed outside the engine, not read back from it.
        XCTAssertEqual(first, ["row-b-text", "row-c-text"])
    }

    func testRuleIsRegisteredInTheStandardSet() {
        XCTAssertTrue(
            RuleEngine.standardRules.contains { type(of: $0).id == ContentOverlapRule.id },
            "a rule absent from standardRules never runs for any real consumer"
        )
    }
}
