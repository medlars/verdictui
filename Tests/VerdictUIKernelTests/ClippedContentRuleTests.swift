import XCTest

@testable import VerdictUIKernel

/// `clipped-content` catches content that escaped its container — visible or
/// cut off, both are defects and both share the same geometry.
///
/// The load-bearing case is ``testContentEscapingAGrandparentIsReported``: a
/// label inside an `HStack` inside a card overflows the CARD while sitting
/// comfortably inside its immediate parent, because the `HStack` grew to fit its
/// child and pushed the problem up a level. A rule checking only the parent
/// passes every simple test and misses exactly the case that reaches a user.
final class ClippedContentRuleTests: XCTestCase {
    private let rule = ClippedContentRule()

    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context() -> LintContext {
        LintContext(scenario: "clipped-content", viewport: Self.viewport)
    }

    private func root(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(id: "root", role: .container, frame: Self.viewport, children: children)
    }

    private func node(
        _ id: String,
        role: Role = .container,
        _ frame: Rect,
        attributes: [String: AttributeValue] = [:],
        isVisible: Bool = true,
        children: [SemanticNode] = []
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: role,
            frame: frame,
            attributes: attributes,
            isVisible: isVisible,
            children: children
        )
    }

    // MARK: - The defect

    func testContentWiderThanItsContainerIsReported() {
        let label = node("label", role: .text, Rect(x: 10, y: 10, width: 240, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [label])

        let findings = rule.evaluate(root([card]), context: context())

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.rule, "clipped-content")
        XCTAssertEqual(findings.first?.nodeID, "label")
        // An escape has no reading under which the author meant it.
        XCTAssertEqual(findings.first?.severity, .error)
        XCTAssertEqual(
            findings.first?.message,
            "'label' extends 50 pt past the trailing edge of 'card'"
        )
        XCTAssertNotNil(findings.first?.suggestion)
    }

    /// The case a parent-only check cannot see. `row` grew to fit `label`, so
    /// `label` fits its parent perfectly — and both escape the card.
    func testContentEscapingAGrandparentIsReported() {
        let label = node("label", role: .text, Rect(x: 0, y: 0, width: 300, height: 20))
        let row = node("row", Rect(x: 0, y: 0, width: 300, height: 20), children: [label])
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [row])

        let findings = rule.evaluate(root([card]), context: context())

        // Both escape the card, and each names the card — the outermost box the
        // content burst out of.
        XCTAssertEqual(findings.map(\.nodeID), ["row", "label"])
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("of 'card'") })
    }

    func testOverflowIsReportedOnWhicheverEdgeIsWorst() {
        // Escapes on both trailing (20) and bottom (60); bottom is worse.
        let content = node("content", role: .image, Rect(x: 0, y: 0, width: 220, height: 160))
        let panel = node("panel", Rect(x: 0, y: 0, width: 200, height: 100), children: [content])

        let findings = rule.evaluate(root([panel]), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'content' extends 60 pt past the bottom edge of 'panel'"
        )
    }

    func testContentEscapingUpwardOrLeftIsReported() {
        let content = node("content", role: .text, Rect(x: -30, y: 20, width: 100, height: 20))
        let panel = node("panel", Rect(x: 0, y: 0, width: 200, height: 100), children: [content])

        let findings = rule.evaluate(root([panel]), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'content' extends 30 pt past the leading edge of 'panel'"
        )
    }

    // MARK: - Shapes that must not report

    func testContentFittingItsContainerIsNotReported() {
        let label = node("label", role: .text, Rect(x: 10, y: 10, width: 100, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [label])

        XCTAssertTrue(rule.evaluate(root([card]), context: context()).isEmpty)
    }

    /// Edge-to-edge content is inside its container, not escaping it. Without
    /// the inclusive comparison every full-bleed image would report.
    func testContentExactlyFillingItsContainerIsNotReported() {
        let image = node("image", role: .image, Rect(x: 0, y: 0, width: 200, height: 100))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [image])

        XCTAssertTrue(rule.evaluate(root([card]), context: context()).isEmpty)
    }

    /// Float noise from layout arithmetic is not an escape — otherwise the rule
    /// reports sub-pixel rounding on real trees constantly.
    func testSubPixelOverflowIsToleratedButRealOverflowIsNot() {
        let noise = node("noise", role: .text, Rect(x: 0, y: 0, width: 200.25, height: 100))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [noise])
        XCTAssertTrue(rule.evaluate(root([card]), context: context()).isEmpty)

        let real = node("real", role: .text, Rect(x: 0, y: 0, width: 202, height: 100))
        let card2 = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [real])
        XCTAssertEqual(rule.evaluate(root([card2]), context: context()).count, 1)
    }

    /// `offscreen` owns content leaving the viewport, and the root IS the
    /// viewport. Reporting both would give one escape two findings in two
    /// vocabularies, and this rule's would be the less accurate.
    func testEscapingTheRootIsLeftToOffscreenRule() {
        let wide = node("wide", role: .text, Rect(x: 0, y: 0, width: 600, height: 20))

        XCTAssertTrue(rule.evaluate(root([wide]), context: context()).isEmpty)
    }

    /// A spacer is a gap; a gap overflowing its container is the container's
    /// layout doing its job, in either role.
    func testSpacersNeitherReportNorAreReportedAgainst() {
        let spacer = node("gap", role: .spacer, Rect(x: 0, y: 0, width: 300, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [spacer])
        XCTAssertTrue(rule.evaluate(root([card]), context: context()).isEmpty)

        // A spacer ancestor must not become the container an escape is measured
        // against; the card above it is the real box.
        let label = node("label", role: .text, Rect(x: 0, y: 0, width: 300, height: 20))
        let spacerParent = node("gap", role: .spacer, Rect(x: 0, y: 0, width: 300, height: 20),
            children: [label])
        let outer = node("card", Rect(x: 0, y: 0, width: 200, height: 100),
            children: [spacerParent])

        let findings = rule.evaluate(root([outer]), context: context())
        XCTAssertEqual(findings.map(\.nodeID), ["label"])
        XCTAssertTrue(findings.allSatisfy { $0.message.contains("of 'card'") })
    }

    func testInvisibleAndUnplaceableNodesAreIgnored() {
        let hidden = node(
            "hidden",
            role: .text,
            Rect(x: 0, y: 0, width: 300, height: 20),
            isVisible: false
        )
        let broken = node("broken", role: .text, Rect(x: 0, y: 0, width: .nan, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100),
            children: [hidden, broken])

        XCTAssertTrue(rule.evaluate(root([card]), context: context()).isEmpty)
    }

    // MARK: - Rule-library contract

    func testSuppressionSilencesOnlyTheTaggedNode() {
        let suppressed = node(
            "suppressed",
            role: .text,
            Rect(x: 0, y: 0, width: 300, height: 20),
            attributes: [LintContext.suppressionKey: .string("clipped-content")]
        )
        let reported = node("reported", role: .text, Rect(x: 0, y: 40, width: 300, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100),
            children: [suppressed, reported])

        let findings = rule.evaluate(root([card]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["reported"])
    }

    func testSeverityOverrideIsHonoured() {
        var overridden = context()
        overridden.severityOverrides = ["clipped-content": .warning]

        let label = node("label", role: .text, Rect(x: 0, y: 0, width: 300, height: 20))
        let card = node("card", Rect(x: 0, y: 0, width: 200, height: 100), children: [label])

        XCTAssertEqual(rule.evaluate(root([card]), context: overridden).first?.severity, .warning)
    }

    func testRuleIsRegisteredInTheStandardSet() {
        XCTAssertTrue(
            RuleEngine.standardRules.contains { type(of: $0).id == ClippedContentRule.id },
            "a rule absent from standardRules never runs for any consumer"
        )
    }

    /// The tolerance is public API, so its VALUE is part of the contract and a
    /// silent drift changes every consumer's verdict.
    ///
    /// It is deliberately the same band the other geometry rules treat as noise:
    /// three rules disagreeing about one hairline teaches an agent to discount
    /// all three, which is worse than any of them not existing.
    func testTheToleranceMatchesTheOtherGeometryRulesNoiseBand() {
        XCTAssertEqual(ClippedContentRule.tolerance, 0.5)
        XCTAssertEqual(
            ClippedContentRule.tolerance,
            SiblingOverlapRule.tolerance,
            "a hairline one geometry rule ignores and another reports is the rules "
                + "disagreeing about identical geometry"
        )
    }
}
