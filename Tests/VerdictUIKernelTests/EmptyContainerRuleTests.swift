import XCTest

@testable import VerdictUIKernel

/// `empty-container` catches area reserved and never filled — the data-driven
/// blank box that every other rule is silent about by construction.
///
/// The negative cases carry most of the weight. A rule that reports childless
/// containers fires constantly on ordinary layout (collapsed sections,
/// conditional branches that correctly rendered nothing), so each shape that
/// must NOT report is pinned here, and each is written so that removing the
/// guard exempting it makes this file fail.
final class EmptyContainerRuleTests: XCTestCase {
    private let rule = EmptyContainerRule()

    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context() -> LintContext {
        LintContext(scenario: "empty-container", viewport: Self.viewport)
    }

    /// A root wrapping `children` plus a painted ``anchor``.
    ///
    /// The anchor is not decoration — without it the ROOT is itself a container
    /// whose subtree renders nothing, so the rule's outermost-only walk reports
    /// the ROOT and never descends to the node the test means to examine. Every
    /// assertion here would then be about `"root"`, which reads exactly like the
    /// rule ignoring its own exemptions.
    ///
    /// Measured, not reasoned: the first draft of this file had the anchor
    /// missing and four cases returned `["root"]`. A fixture that does not reach
    /// the code under test is not a weak test, it is aimed somewhere else
    /// (`no.md` #18), so the anchor lives in the helper where no call site can
    /// forget it rather than being pasted into each test.
    private func root(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: Self.viewport,
            children: children + [anchor]
        )
    }

    /// Real painted content — a `text` node, which is content in its own right.
    private var anchor: SemanticNode {
        SemanticNode(id: "anchor", role: .text, frame: Rect(x: 0, y: 280, width: 100, height: 20))
    }

    /// A container that reserves area and holds only a non-painting child.
    ///
    /// The rule declines to judge a CHILDLESS container (it may be a decorative
    /// shape that paints itself — see
    /// ``testAChildlessContainerIsNotReportedBecauseItMayPaintItself``), so a
    /// fixture meaning "this container is blank" must give it a child that does
    /// not paint. Without one, a test asserting a finding is asserting against
    /// a shape the rule deliberately says nothing about.
    private func blankContainer(
        _ id: String,
        role: Role = .container,
        frame: Rect = Rect(x: 0, y: 0, width: 200, height: 120),
        attributes: [String: AttributeValue] = [:]
    ) -> SemanticNode {
        box(
            id,
            role: role,
            frame: frame,
            attributes: attributes,
            children: [
                box("\(id)-void", frame: Rect(x: frame.x, y: frame.y, width: 10, height: 10))
            ]
        )
    }

    private func box(
        _ id: String,
        role: Role = .container,
        frame: Rect = Rect(x: 0, y: 0, width: 200, height: 120),
        isVisible: Bool = true,
        attributes: [String: AttributeValue] = [:],
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

    /// The real defect shape: the author put something inside and nothing came
    /// out — an empty `ForEach` still emits its host row, a false conditional
    /// branch still emits its wrapper.
    func testAContainerWhoseChildrenAllFailToPaintIsReported() {
        let emptyRow = box("row", role: .listRow, frame: Rect(x: 0, y: 0, width: 200, height: 120),
            children: [box("cell", frame: Rect(x: 0, y: 0, width: 180, height: 100))])

        let findings = rule.evaluate(
            root([box("results-list", role: .list, children: [emptyRow])]),
            context: context()
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.rule, "empty-container")
        XCTAssertEqual(findings.first?.nodeID, "results-list")
        XCTAssertEqual(findings.first?.severity, .warning)
        // The message must carry the reserved area, because that is the evidence
        // distinguishing this from a correctly-collapsed container.
        XCTAssertEqual(
            findings.first?.message,
            "'results-list' reserves 200 x 120 pt but renders nothing"
        )
        XCTAssertNotNil(findings.first?.suggestion)
    }

    /// The false-positive case that decided this rule's scope, kept as a test so
    /// nobody widens it back.
    ///
    /// A probed leaf that paints itself — a `RoundedRectangle` fill, a capsule
    /// background, a divider — has zero children and no attribute saying it
    /// draws, so it is indistinguishable from a container whose content never
    /// arrived. Measured: the first version of this rule reported `card-surface`
    /// and `card-pill` in `CleanSettingsScenario`, the reference CORRECT UI
    /// whose entire job is to produce zero findings.
    func testAChildlessContainerIsNotReportedBecauseItMayPaintItself() {
        let decoration = box("card-surface", frame: Rect(x: 0, y: 0, width: 220, height: 64))

        XCTAssertTrue(
            rule.evaluate(root([decoration]), context: context()).isEmpty,
            "a childless container may be a decorative shape; the tree cannot tell"
        )
    }

    /// The commonest real spelling: the container wraps another container that
    /// itself failed to render. A `children.isEmpty` check cannot see this —
    /// `outer` HAS a child, and that child is a visible non-spacer with real
    /// area, so a naive "has children" test reports it as content.
    ///
    /// Exactly ONE finding, naming the OUTERMOST node. A blank
    /// `VStack { HStack { } }` is one defect, and reporting every empty node on
    /// the chain turns an N-deep wrapper into N findings for a single blank
    /// region — the "one defect counted N times" shape that makes a backlog
    /// unreadable. The outermost node is also the one an author fixes: it names
    /// the whole region a human sees blank.
    func testANestedChainOfEmptyContainersReportsOnlyTheOutermost() {
        let inner = box("inner", frame: Rect(x: 0, y: 0, width: 180, height: 100))
        let outer = box("outer", children: [inner])

        let findings = rule.evaluate(root([outer]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["outer"])
    }

    /// The counterpart to outermost-only reporting: suppressing the wrapper must
    /// NOT silence the subtree beneath it.
    ///
    /// The walk stops descending only when a finding was actually PRODUCED, so a
    /// suppressed node keeps descending. Written because the obvious
    /// implementation — stop descending whenever the node is reportable —
    /// converts a one-node suppression into a whole-subtree blindfold, and the
    /// author who wrote `verdict.suppress` on one container would never learn
    /// the empty child inside it exists.
    func testSuppressingAWrapperRevealsTheEmptyContainerInsideIt() {
        let inner = blankContainer("inner", frame: Rect(x: 0, y: 0, width: 180, height: 100))
        let outer = box(
            "outer",
            attributes: [LintContext.suppressionKey: .string("empty-container")],
            children: [inner]
        )

        let findings = rule.evaluate(root([outer]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["inner"])
    }

    /// Spacers occupy space and render nothing — that is their documented job —
    /// so a container holding only spacers is exactly the blank box this rule
    /// exists to name. Counting them as content would make the rule unable to
    /// fire on `VStack { Spacer() }`, where the content was meant to be.
    func testAContainerHoldingOnlySpacersIsEmpty() {
        let spacer = SemanticNode(
            id: "gap",
            role: .spacer,
            frame: Rect(x: 0, y: 0, width: 200, height: 120)
        )

        let findings = rule.evaluate(root([box("card", children: [spacer])]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["card"])
    }

    func testAContainerWhoseOnlyChildrenAreInvisibleIsEmpty() {
        let hidden = box("hidden-row", role: .listRow, isVisible: false)

        let findings = rule.evaluate(root([box("list", role: .list, children: [hidden])]),
            context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["list"])
    }

    // MARK: - Shapes that must not report

    /// A zero-area container is the ORDINARY case — collapsed disclosure groups,
    /// conditional branches that correctly rendered nothing. Firing here would
    /// report normal layout constantly, which is how a rule gets switched off.
    func testAZeroAreaContainerIsNotReported() {
        let collapsed = box("collapsed", frame: Rect(x: 0, y: 0, width: 200, height: 0))

        XCTAssertTrue(rule.evaluate(root([collapsed]), context: context()).isEmpty)
    }

    func testAContainerBelowTheMinimumReportableAreaIsNotReported() {
        // A hairline divider-sized box is not a visible blank region.
        let hairline = box("hairline", frame: Rect(x: 0, y: 0, width: 200, height: 0.5))

        XCTAssertTrue(rule.evaluate(root([hairline]), context: context()).isEmpty)
    }

    func testAContainerThatRendersRealContentIsNotReported() {
        let label = SemanticNode(
            id: "title",
            role: .text,
            frame: Rect(x: 0, y: 0, width: 100, height: 20)
        )

        XCTAssertTrue(
            rule.evaluate(root([box("card", children: [label])]), context: context()).isEmpty
        )
    }

    /// Content nested two levels down still counts — the recursion must find it,
    /// or every wrapping container in a real tree reports falsely.
    func testContentNestedBelowAnEmptyWrapperCountsForAllItsAncestors() {
        let label = SemanticNode(
            id: "title",
            role: .text,
            frame: Rect(x: 0, y: 0, width: 100, height: 20)
        )
        let inner = box("inner", children: [label])

        XCTAssertTrue(
            rule.evaluate(root([box("outer", children: [inner])]), context: context()).isEmpty
        )
    }

    /// An invisible container is not a visible blank region, however large.
    func testAnInvisibleContainerIsNotReported() {
        XCTAssertTrue(
            rule.evaluate(root([box("offscreen", isVisible: false)]), context: context())
                .isEmpty
        )
    }

    /// Roles outside the policed set are exempt for stated reasons: a childless
    /// `button` carries its label in `text`, an `image` has no children by
    /// nature, and a `custom` role means the probe could not classify the node —
    /// calling an unclassified node an empty container states more than the
    /// tree supports.
    func testUnpolicedRolesAreNotReported() {
        let cases: [Role] = [.button, .image, .text, .toggle, .custom("unclassified")]

        for role in cases {
            let findings = rule.evaluate(root([box("node", role: role)]), context: context())
            XCTAssertTrue(findings.isEmpty, "\(role.identifier) must not be policed")
        }
    }

    /// A NaN or infinite frame cannot be placed at all; `zero-size` owns that
    /// defect. Reporting it here would name the wrong rule in the evidence.
    func testANonFiniteFrameIsLeftToZeroSizeRule() {
        let broken = box("broken", frame: Rect(x: 0, y: 0, width: .nan, height: 120))
        let infinite = box("infinite", frame: Rect(x: 0, y: 0, width: .infinity, height: 120))

        XCTAssertTrue(rule.evaluate(root([broken, infinite]), context: context()).isEmpty)
    }

    // MARK: - Rule-library contract

    func testSuppressionSilencesOnlyTheTaggedNode() {
        let suppressed = blankContainer(
            "suppressed",
            attributes: [LintContext.suppressionKey: .string("empty-container")]
        )
        let reported = blankContainer(
            "reported",
            frame: Rect(x: 0, y: 140, width: 200, height: 120)
        )

        let findings = rule.evaluate(root([suppressed, reported]), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["reported"])
    }

    func testSeverityOverrideIsHonoured() {
        var overridden = context()
        overridden.severityOverrides = ["empty-container": .error]

        let findings = rule.evaluate(root([blankContainer("card")]), context: overridden)

        XCTAssertEqual(findings.first?.severity, .error)
    }

    func testDisablingTheRuleSilencesItInTheEngine() {
        var disabled = context()
        disabled.disabledRules = ["empty-container"]

        let verdict = RuleEngine.run(
            rules: [rule],
            on: root([blankContainer("card")]),
            context: disabled
        )

        XCTAssertTrue(verdict.findings.filter { $0.rule == "empty-container" }.isEmpty)
    }

    func testRuleIsRegisteredInTheStandardSet() {
        XCTAssertTrue(
            RuleEngine.standardRules.contains { type(of: $0).id == EmptyContainerRule.id },
            "a rule absent from standardRules never runs for any consumer"
        )
    }

    /// The threshold is public API, so its VALUE is part of the contract and a
    /// silent drift changes every consumer's verdict. Pinned with the reasoning
    /// attached: a whole point rather than the 0.5 pt float-noise band the
    /// overlap rules use, because this is not a rounding tolerance — it is a
    /// claim about what a human can see.
    func testTheMinimumReportableAreaIsAVisibilityClaimNotAFloatTolerance() {
        XCTAssertEqual(EmptyContainerRule.minimumReportableArea, 1.0)
        XCTAssertGreaterThan(
            EmptyContainerRule.minimumReportableArea,
            SiblingOverlapRule.tolerance,
            "a visibility threshold must sit above the float-noise band, or the rule "
                + "reports hairlines nobody can see"
        )
    }
}
