import XCTest

@testable import VerdictUIKernel

/// `misalignment` catches the "2 px off" class — edges the author meant to line
/// up and missed.
///
/// The rule lives or dies on its WINDOW, so the boundary cases carry more weight
/// than the positive ones. Exact alignment must be silent, a deliberate indent
/// must be silent, and only the narrow band between them may report. Each end of
/// that window is pinned here, because a rule that fired on every unaligned edge
/// would report most of a real screen and be switched off within a day.
final class MisalignmentRuleTests: XCTestCase {
    private let rule = MisalignmentRule()

    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context() -> LintContext {
        LintContext(scenario: "misalignment", viewport: Self.viewport)
    }

    private func root(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(id: "root", role: .container, frame: Self.viewport, children: children)
    }

    /// A row at `x`, stacked vertically by index so siblings never overlap —
    /// this rule is about edges, and an overlap would be a different rule's
    /// finding contaminating the fixture.
    private func row(
        _ id: String,
        x: Double,
        width: Double = 100,
        index: Int,
        role: Role = .text,
        attributes: [String: AttributeValue] = [:]
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: role,
            frame: Rect(x: x, y: Double(index) * 40, width: width, height: 20),
            attributes: attributes
        )
    }

    // MARK: - The defect

    func testANearMissOnTheLeadingEdgeIsReported() {
        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), row("second", x: 18, index: 1)]),
            context: context()
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.rule, "misalignment")
        XCTAssertEqual(findings.first?.nodeID, "second")
        XCTAssertEqual(findings.first?.severity, .warning)
        // Both edge values belong in the message: "off by 2" is not actionable
        // without knowing which two numbers disagree.
        XCTAssertEqual(
            findings.first?.message,
            "'second' misses leading alignment with 'first' by 2 pt (18 vs 16)"
        )
        XCTAssertNotNil(findings.first?.suggestion)
    }

    func testANearMissOnTheTrailingEdgeIsReported() {
        // Same leading edge, different widths — only the trailing edges miss.
        let findings = rule.evaluate(
            root([
                row("first", x: 16, width: 100, index: 0),
                row("second", x: 16, width: 103, index: 1),
            ]),
            context: context()
        )

        XCTAssertEqual(findings.map(\.nodeID), ["second"])
        XCTAssertTrue(
            findings.first?.message.contains("trailing") == true,
            "the finding must name the edge that missed, got: \(findings.first?.message ?? "none")"
        )
    }

    /// Vertical edges are policed on the same terms as horizontal ones —
    /// a rule that only ever compared `x` would pass every test written with
    /// side-by-side fixtures and be blind to half its subject.
    func testANearMissOnAVerticalEdgeIsReported() {
        let left = SemanticNode(id: "left", role: .text, frame: Rect(x: 0, y: 10, width: 80, height: 20))
        let right = SemanticNode(id: "right", role: .text, frame: Rect(x: 120, y: 13, width: 80, height: 20))

        let findings = rule.evaluate(root([left, right]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["right"])
        XCTAssertTrue(findings.first?.message.contains("top") == true)
    }

    // MARK: - The window — both ends pinned

    /// Exact alignment is the intended case and must be silent.
    func testExactlyAlignedEdgesAreNotReported() {
        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), row("second", x: 16, index: 1)]),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty, "exact alignment is the goal, not a finding")
    }

    /// Float noise from layout arithmetic is not a misalignment. Without this
    /// the rule would report sub-pixel rounding on real trees constantly.
    func testSubPixelDeviationIsTreatedAsAlignment() {
        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), row("second", x: 16.25, index: 1)]),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    /// The upper end of the window: a deliberate indent is design, not a defect.
    /// This is the assertion that keeps the rule usable — remove it and the rule
    /// reports every nested hierarchy and two-column layout in existence.
    func testADeliberateIndentIsNotReported() {
        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), row("indented", x: 48, index: 1)]),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty, "a 32 pt indent is a layout decision, not a near-miss")
    }

    /// The boundary itself, asserted from both sides so the comparison cannot
    /// silently become `<=` or `>=` without this file noticing.
    func testTheToleranceBoundaryIsExclusive() {
        let justInside = rule.evaluate(
            root([row("a", x: 16, index: 0), row("b", x: 16 + 3.9, index: 1)]),
            context: context()
        )
        XCTAssertEqual(justInside.count, 1, "3.9 pt is inside the 4 pt window")

        let atBoundary = rule.evaluate(
            root([row("a", x: 16, index: 0), row("b", x: 16 + 4.0, index: 1)]),
            context: context()
        )
        XCTAssertTrue(atBoundary.isEmpty, "4 pt reads as deliberate spacing")
    }

    // MARK: - Noise control

    /// One defect, one finding. Comparing every pair would report a three-element
    /// near-miss three times, and a rule that multiplies its own evidence makes
    /// a backlog unreadable.
    func testEachNodeIsReportedOncePerEdgeAgainstItsNearestEarlierSibling() {
        let findings = rule.evaluate(
            root([
                row("first", x: 16, index: 0),
                row("second", x: 18, index: 1),
                row("third", x: 19, index: 2),
            ]),
            context: context()
        )

        // Two findings, not three: each later node names one reference.
        XCTAssertEqual(findings.map(\.nodeID), ["second", "third"])
    }

    /// A node exactly aligned with an earlier sibling has satisfied the intent,
    /// even when a THIRD sibling sits at a near-miss distance. Without the early
    /// exit, a correctly-aligned pair reports because some other row was sloppy.
    func testANodeAlignedWithAnEarlierSiblingIsSilentDespiteANearMissElsewhere() {
        let findings = rule.evaluate(
            root([
                row("reference", x: 16, index: 0),
                row("sloppy", x: 18, index: 1),
                row("aligned", x: 16, index: 2),
            ]),
            context: context()
        )

        XCTAssertEqual(
            findings.map(\.nodeID),
            ["sloppy"],
            "'aligned' matches 'reference' exactly and must not be blamed for 'sloppy'"
        )
    }

    /// A spacer is a gap; its edges are wherever the layout pushed them, so it
    /// carries no alignment intent in either direction.
    func testSpacersAreNotComparedInEitherDirection() {
        let spacer = SemanticNode(
            id: "gap",
            role: .spacer,
            frame: Rect(x: 18, y: 40, width: 100, height: 20)
        )

        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), spacer, row("third", x: 18, index: 2)]),
            context: context()
        )

        // 'third' still misses 'first'; the spacer neither reports nor is a reference.
        XCTAssertEqual(findings.map(\.nodeID), ["third"])
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("gap") == false })
    }

    func testInvisibleAndUnplaceableNodesAreIgnored() {
        let hidden = SemanticNode(
            id: "hidden",
            role: .text,
            frame: Rect(x: 18, y: 40, width: 100, height: 20),
            isVisible: false
        )
        let broken = SemanticNode(
            id: "broken",
            role: .text,
            frame: Rect(x: 18, y: 80, width: .nan, height: 20)
        )

        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), hidden, broken]),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    /// Nodes under different parents are not compared: alignment is a claim
    /// about siblings, and cross-branch comparison would report every column of
    /// every unrelated section against every other.
    func testNodesUnderDifferentParentsAreNotCompared() {
        let leftColumn = SemanticNode(
            id: "left-column",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 190, height: 300),
            children: [row("a", x: 16, index: 0)]
        )
        let rightColumn = SemanticNode(
            id: "right-column",
            role: .container,
            frame: Rect(x: 200, y: 0, width: 190, height: 300),
            children: [row("b", x: 18, index: 0)]
        )

        let findings = rule.evaluate(root([leftColumn, rightColumn]), context: context())

        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Rule-library contract

    func testSuppressionSilencesOnlyTheTaggedNode() {
        let findings = rule.evaluate(
            root([
                row("first", x: 16, index: 0),
                row(
                    "suppressed",
                    x: 18,
                    index: 1,
                    attributes: [LintContext.suppressionKey: .string("misalignment")]
                ),
            ]),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    func testSeverityOverrideIsHonoured() {
        var overridden = context()
        overridden.severityOverrides = ["misalignment": .error]

        let findings = rule.evaluate(
            root([row("first", x: 16, index: 0), row("second", x: 18, index: 1)]),
            context: overridden
        )

        XCTAssertEqual(findings.first?.severity, .error)
    }

    func testRuleIsRegisteredInTheStandardSet() {
        XCTAssertTrue(
            RuleEngine.standardRules.contains { type(of: $0).id == MisalignmentRule.id },
            "a rule absent from standardRules never runs for any consumer"
        )
    }

    /// Both thresholds are public API, so their VALUES are part of the contract
    /// and a silent drift changes every consumer's verdict.
    ///
    /// The ORDER between them is the property that actually matters: the window
    /// only exists while the noise floor sits strictly below the intent ceiling.
    /// If they ever crossed, every deviation would be either noise or deliberate
    /// and the rule could never fire — a rule that has quietly stopped being a
    /// rule, with no test able to notice.
    func testTheAlignmentWindowHasBothEndsAndTheyAreInOrder() {
        XCTAssertEqual(MisalignmentRule.coincidenceTolerance, 0.5)
        XCTAssertEqual(MisalignmentRule.alignmentTolerance, 4.0)
        XCTAssertLessThan(
            MisalignmentRule.coincidenceTolerance,
            MisalignmentRule.alignmentTolerance,
            "with the thresholds crossed the reportable window is empty and the rule "
                + "can never fire for any geometry"
        )
    }
}
