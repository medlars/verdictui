import XCTest

@testable import VerdictUIKernel

/// Shared fixtures for the six Wave 1 rules.
private enum Fixture {
    static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    static func context(
        minimumTapTarget: Size = LintContext.macOSMinimumTapTarget,
        truncationTolerance: Double = 0.5
    ) -> LintContext {
        LintContext(
            scenario: "rules",
            viewport: viewport,
            minimumTapTarget: minimumTapTarget,
            truncationTolerance: truncationTolerance
        )
    }

    static func root(_ children: [SemanticNode], role: Role = .container) -> SemanticNode {
        SemanticNode(id: "root", role: role, frame: viewport, children: children)
    }

    static func suppressed(_ node: SemanticNode, rules: String) -> SemanticNode {
        var copy = node
        copy.attributes[LintContext.suppressionKey] = .string(rules)
        return copy
    }
}

// MARK: - sibling-overlap

final class SiblingOverlapRuleTests: XCTestCase {
    private let rule = SiblingOverlapRule()

    private func box(_ id: String, x: Double, width: Double = 60) -> SemanticNode {
        SemanticNode(id: id, role: .button, frame: Rect(x: x, y: 0, width: width, height: 40))
    }

    func testOverlapIsReportedOnTheUpperSiblingWithMeasuredArea() throws {
        let tree = Fixture.root([box("a", x: 0), box("b", x: 50)])
        let findings = rule.evaluate(tree, context: Fixture.context())
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.rule, "sibling-overlap")
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.nodeID, "b")
        XCTAssertEqual(finding.message, "'b' overlaps sibling 'a' by 10 x 40 pt")
        XCTAssertNotNil(finding.suggestion)
    }

    func testDisjointAndEdgeTouchingSiblingsPass() {
        XCTAssertTrue(rule.evaluate(Fixture.root([box("a", x: 0), box("b", x: 80)]), context: Fixture.context()).isEmpty)
        XCTAssertTrue(
            rule.evaluate(Fixture.root([box("a", x: 0), box("b", x: 60)]), context: Fixture.context())
                .isEmpty,
            "shared edges are adjacency, not overlap"
        )
    }

    func testEmptyOrInvisibleSiblingsAreIgnored() {
        var invisible = box("b", x: 50)
        invisible.isVisible = false
        XCTAssertTrue(rule.evaluate(Fixture.root([box("a", x: 0), invisible]), context: Fixture.context()).isEmpty)

        let empty = SemanticNode(id: "b", role: .button, frame: Rect(x: 10, y: 10, width: 0, height: 0))
        XCTAssertTrue(rule.evaluate(Fixture.root([box("a", x: 0), empty]), context: Fixture.context()).isEmpty)
    }

    func testExplicitZIndexReadsAsIntentionalLayering() {
        var layered = box("b", x: 50)
        layered.zIndex = 1
        XCTAssertTrue(rule.evaluate(Fixture.root([box("a", x: 0), layered]), context: Fixture.context()).isEmpty)
    }

    func testZStackParentRoleReadsAsIntentionalLayering() {
        // Case-insensitive on purpose, and every casing is held here: "zstack"
        // is the form the probe target actually deploys (CleanSettingsScenario),
        // so a comparison that quietly became case-sensitive would exonerate
        // nothing while this test kept passing on "ZStack" alone.
        for casing in ["ZStack", "zstack", "ZSTACK"] {
            let tree = Fixture.root([box("a", x: 0), box("b", x: 50)], role: .custom(casing))
            XCTAssertTrue(
                rule.evaluate(tree, context: Fixture.context()).isEmpty,
                "a parent role of '\(casing)' did not read as intentional layering"
            )
        }
    }

    func testOverlapIsDetectedInNestedContainersAndCousinsAreNotCompared() {
        let tree = Fixture.root([
            SemanticNode(
                id: "left",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 200, height: 100),
                children: [box("a", x: 0), box("b", x: 50)]
            ),
            SemanticNode(
                id: "right",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 200, height: 100),
                children: [box("c", x: 0)]
            ),
        ])
        // 'left' and 'right' overlap each other, and 'a'/'b' overlap inside 'left':
        // two findings, and no cross-parent comparison between 'a' and 'c'.
        XCTAssertEqual(
            rule.evaluate(tree, context: Fixture.context()).map(\.nodeID),
            ["right", "b"]
        )
    }

    func testSuppressionSilencesOnlyTheTaggedNode() {
        let tree = Fixture.root([box("a", x: 0), Fixture.suppressed(box("b", x: 50), rules: "sibling-overlap")])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }
}

// MARK: - zero-size

final class ZeroSizeRuleTests: XCTestCase {
    private let rule = ZeroSizeRule()

    private func node(_ id: String, role: Role, width: Double = 0, height: Double = 0) -> SemanticNode {
        SemanticNode(id: id, role: role, frame: Rect(x: 0, y: 0, width: width, height: height))
    }

    func testVisibleTextWithAnEmptyFrameIsAnError() throws {
        let findings = rule.evaluate(Fixture.root([node("title", role: .text)]), context: Fixture.context())
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.nodeID, "title")
        XCTAssertEqual(finding.message, "'title' is visible but its frame is 0 x 0 pt")
    }

    func testInteractiveIsAnErrorAndOtherRolesAreWarnings() {
        let findings = rule.evaluate(
            Fixture.root([node("btn", role: .button), node("img", role: .image), node("box", role: .container)]),
            context: Fixture.context()
        )
        XCTAssertEqual(findings.map(\.nodeID), ["btn", "img", "box"])
        XCTAssertEqual(findings.map(\.severity), [.error, .warning, .warning])
    }

    func testCollapsedInOneDimensionOnlyStillCounts() {
        let findings = rule.evaluate(
            Fixture.root([node("wide", role: .text, width: 100, height: 0)]),
            context: Fixture.context()
        )
        XCTAssertEqual(findings.first?.message, "'wide' is visible but its frame is 100 x 0 pt")
    }

    func testSpacerAndProbeScaffoldingAreExemptByRole() {
        XCTAssertEqual(ZeroSizeRule.probeRolePrefix, "verdict.")
        let tree = Fixture.root([
            node("gap", role: .spacer),
            node("probe", role: .custom(ZeroSizeRule.probeRolePrefix + "anchor")),
        ])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)

        // The exemption is the prefix, not the word: a role that merely mentions
        // it elsewhere is still policed.
        let misleading = Fixture.root([node("late", role: .custom("nested.verdict.anchor"))])
        XCTAssertEqual(rule.evaluate(misleading, context: Fixture.context()).count, 1)
    }

    func testInvisibleNodesAndSizedNodesPass() {
        var hidden = node("hidden", role: .text)
        hidden.isVisible = false
        let tree = Fixture.root([hidden, node("sized", role: .text, width: 10, height: 10)])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }

    func testSuppressionSilencesTheNode() {
        let tree = Fixture.root([Fixture.suppressed(node("title", role: .text), rules: "zero-size")])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }
}

// MARK: - offscreen

final class OffscreenRuleTests: XCTestCase {
    private let rule = OffscreenRule()

    private func node(_ id: String, x: Double, y: Double = 10, role: Role = .button) -> SemanticNode {
        SemanticNode(id: id, role: role, frame: Rect(x: x, y: y, width: 60, height: 40))
    }

    func testFullyOutsideViewportIsAnError() throws {
        let findings = rule.evaluate(Fixture.root([node("hidden", x: 420)]), context: Fixture.context())
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(
            finding.message,
            "'hidden' is visible but sits entirely outside the 400 x 300 pt viewport "
                + "(frame origin 420, 10)"
        )
    }

    func testNegativeCoordinatesCountAsOffscreen() {
        let findings = rule.evaluate(Fixture.root([node("above", x: 10, y: -80)]), context: Fixture.context())
        XCTAssertEqual(findings.map(\.nodeID), ["above"])
    }

    func testPartiallyVisibleAndFullyVisibleNodesPass() {
        let tree = Fixture.root([node("clipped", x: 380), node("inside", x: 10)])
        XCTAssertTrue(
            rule.evaluate(tree, context: Fixture.context()).isEmpty,
            "edge clipping is normal for scrolling layouts — ClippedContentRule judges it in Wave 5"
        )
    }

    func testInvisibleEmptyAndSpacerNodesAreIgnored() {
        var hidden = node("hidden", x: 420)
        hidden.isVisible = false
        let empty = SemanticNode(id: "empty", role: .button, frame: Rect(x: 500, y: 0, width: 0, height: 0))
        let tree = Fixture.root([hidden, empty, node("gap", x: 420, role: .spacer)])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }

    func testSuppressionSilencesTheNode() {
        let tree = Fixture.root([Fixture.suppressed(node("hidden", x: 420), rules: "offscreen")])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }
}

// MARK: - truncation

final class TruncationRuleTests: XCTestCase {
    private let rule = TruncationRule()

    private func text(
        _ id: String,
        width: Double,
        metrics: TextMetrics?
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: .text,
            frame: Rect(x: 0, y: 0, width: width, height: 20),
            text: "Monthly summary",
            textMetrics: metrics
        )
    }

    func testFewerRenderedLinesThanWantedIsAnError() throws {
        let node = text(
            "title",
            width: 120,
            metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 3)
        )
        let finding = try XCTUnwrap(rule.evaluate(Fixture.root([node]), context: Fixture.context()).first)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.message, "'title' rendered 1 of 3 lines")
        XCTAssertEqual(finding.suggestion, "allow 3 lines (.lineLimit(3)) or increase the frame height")
    }

    func testSingleLineNarrowerThanItsIntrinsicWidthIsAnError() throws {
        let node = text(
            "title",
            width: 120,
            metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 1)
        )
        let finding = try XCTUnwrap(rule.evaluate(Fixture.root([node]), context: Fixture.context()).first)
        XCTAssertEqual(finding.message, "'title' needs 212 pt of width on one line but was given 120 pt")
        XCTAssertEqual(finding.suggestion, "increase frame width to >= intrinsicWidth 212 pt, or allow wrapping")
    }

    func testMultiLineTextNarrowerThanIntrinsicWidthIsWrappingNotTruncation() {
        let node = text(
            "body",
            width: 120,
            metrics: TextMetrics(intrinsicWidth: 400, renderedLineCount: 4, idealLineCount: 4)
        )
        XCTAssertTrue(rule.evaluate(Fixture.root([node]), context: Fixture.context()).isEmpty)
    }

    func testSubPointShortfallIsAbsorbedByTheTolerance() {
        let node = text(
            "title",
            width: 211.7,
            metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 1)
        )
        XCTAssertTrue(
            rule.evaluate(Fixture.root([node]), context: Fixture.context()).isEmpty,
            "layout rounding is not a defect"
        )
        XCTAssertEqual(
            rule.evaluate(Fixture.root([node]), context: Fixture.context(truncationTolerance: 0)).count,
            1,
            "a zero tolerance must still catch it"
        )
    }

    func testNodesWithoutMetricsOrVisibilityAreSkipped() {
        var hidden = text(
            "hidden",
            width: 10,
            metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 3)
        )
        hidden.isVisible = false
        let tree = Fixture.root([text("unmeasured", width: 10, metrics: nil), hidden])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }

    func testIntactTextPasses() {
        let node = text(
            "title",
            width: 220,
            metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 1)
        )
        XCTAssertTrue(rule.evaluate(Fixture.root([node]), context: Fixture.context()).isEmpty)
    }

    func testSuppressionSilencesTheNode() {
        let node = Fixture.suppressed(
            text(
                "title",
                width: 120,
                metrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 3)
            ),
            rules: "truncation"
        )
        XCTAssertTrue(rule.evaluate(Fixture.root([node]), context: Fixture.context()).isEmpty)
    }
}

// MARK: - tap-target

final class TapTargetRuleTests: XCTestCase {
    private let rule = TapTargetRule()

    private func control(
        _ id: String,
        role: Role = .button,
        width: Double,
        height: Double
    ) -> SemanticNode {
        SemanticNode(id: id, role: role, frame: Rect(x: 0, y: 0, width: width, height: height))
    }

    func testUndersizedControlIsReportedAgainstTheMacOSMinimum() throws {
        let findings = rule.evaluate(
            Fixture.root([control("close", width: 24, height: 18)]),
            context: Fixture.context()
        )
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.message, "'close' is 24 x 18 pt, below the 28 x 28 pt minimum hit size")
        XCTAssertEqual(finding.suggestion, "grow the control or add .frame(minWidth: 28, minHeight: 28)")
    }

    func testOneUndersizedDimensionIsEnough() {
        let findings = rule.evaluate(
            Fixture.root([control("tall", width: 20, height: 100)]),
            context: Fixture.context()
        )
        XCTAssertEqual(findings.map(\.nodeID), ["tall"])
    }

    func testControlsAtOrAboveTheMinimumPass() {
        let tree = Fixture.root([control("ok", width: 28, height: 28)])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }

    func testTouchContextEnforcesTheLargerMinimum() {
        let tree = Fixture.root([control("ok-on-mac", width: 30, height: 30)])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
        XCTAssertEqual(
            rule.evaluate(tree, context: Fixture.context(minimumTapTarget: LintContext.touchMinimumTapTarget))
                .first?.message,
            "'ok-on-mac' is 30 x 30 pt, below the 44 x 44 pt minimum hit size"
        )
    }

    func testEveryInteractiveRoleIsPolicedAndStaticRolesAreNot() {
        let interactive: [Role] = [.button, .toggle, .slider, .textField, .menu]
        let static_: [Role] = [.text, .image, .container, .list, .listRow, .navigation, .tabBar]
        let tree = Fixture.root(
            (interactive + static_).enumerated().map { index, role in
                control("n\(index)", role: role, width: 10, height: 10)
            }
        )
        XCTAssertEqual(
            rule.evaluate(tree, context: Fixture.context()).count,
            interactive.count
        )
    }

    func testEmptyFramesAreLeftToZeroSizeRuleAndInvisibleNodesSkipped() {
        var hidden = control("hidden", width: 10, height: 10)
        hidden.isVisible = false
        let tree = Fixture.root([control("empty", width: 0, height: 0), hidden])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }

    func testSuppressionSilencesTheNode() {
        let tree = Fixture.root([Fixture.suppressed(control("close", width: 10, height: 10), rules: "tap-target")])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }
}

// MARK: - duplicate-probe-id

final class DuplicateProbeIDRuleTests: XCTestCase {
    private let rule = DuplicateProbeIDRule()

    private func leaf(_ id: String, y: Double = 0) -> SemanticNode {
        SemanticNode(id: id, role: .button, frame: Rect(x: 0, y: y, width: 40, height: 40))
    }

    func testRepeatedIDIsAnErrorReportedOnce() throws {
        let tree = Fixture.root([leaf("save"), leaf("save", y: 50), leaf("save", y: 100)])
        let findings = rule.evaluate(tree, context: Fixture.context())
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1, "one finding per colliding id, not per occurrence")
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.nodeID, "save")
        XCTAssertTrue(finding.message.contains("appears 3 times"), finding.message)
    }

    func testCollisionsAcrossDifferentParentsAreDetected() {
        let tree = Fixture.root([
            SemanticNode(
                id: "left",
                role: .container,
                frame: Fixture.viewport,
                children: [leaf("save")]
            ),
            SemanticNode(
                id: "right",
                role: .container,
                frame: Fixture.viewport,
                children: [leaf("save", y: 50)]
            ),
        ])
        XCTAssertEqual(rule.evaluate(tree, context: Fixture.context()).map(\.nodeID), ["save"])
    }

    func testMultipleCollidingIDsAreReportedInSortedOrder() {
        let tree = Fixture.root([leaf("zulu"), leaf("zulu", y: 20), leaf("alpha", y: 40), leaf("alpha", y: 60)])
        XCTAssertEqual(
            rule.evaluate(tree, context: Fixture.context()).map(\.nodeID),
            ["alpha", "zulu"],
            "sorted for a stable wire format"
        )
    }

    func testUniqueIDsAndUnprobedNodesPass() {
        let tree = Fixture.root([
            leaf("a"),
            leaf("b", y: 50),
            SemanticNode(id: "", role: .text, frame: Rect(x: 0, y: 0, width: 5, height: 5)),
            SemanticNode(id: "", role: .text, frame: Rect(x: 0, y: 10, width: 5, height: 5)),
        ])
        XCTAssertTrue(
            rule.evaluate(tree, context: Fixture.context()).isEmpty,
            "unprobed nodes are identified by structural path, not by the empty id"
        )
    }

    func testInvisibleDuplicatesStillCountBecauseDiffingBreaksRegardless() {
        var hidden = leaf("save", y: 50)
        hidden.isVisible = false
        XCTAssertEqual(rule.evaluate(Fixture.root([leaf("save"), hidden]), context: Fixture.context()).count, 1)
    }

    func testSuppressionOnTheFirstOccurrenceSilencesTheFinding() {
        let tree = Fixture.root([Fixture.suppressed(leaf("save"), rules: "duplicate-probe-id"), leaf("save", y: 50)])
        XCTAssertTrue(rule.evaluate(tree, context: Fixture.context()).isEmpty)
    }
}

// MARK: - standard rule set

final class StandardRuleSetTests: XCTestCase {

    func testStandardRulesAreTheSixWave1RulesWithIDFirst() {
        XCTAssertEqual(
            RuleEngine.standardRules.map { type(of: $0).id },
            ["duplicate-probe-id", "zero-size", "sibling-overlap", "offscreen", "truncation", "tap-target"]
        )
    }

    /// A correct UI must produce no findings at all — the false-positive guard the
    /// Wave 1 risk register calls out.
    func testACleanTreePassesEveryRule() {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Fixture.viewport,
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    frame: Rect(x: 16, y: 16, width: 240, height: 20),
                    text: "Monthly summary",
                    textMetrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 1)
                ),
                SemanticNode(id: "gap", role: .spacer, frame: Rect(x: 16, y: 36, width: 0, height: 0)),
                SemanticNode(id: "save", role: .button, frame: Rect(x: 16, y: 48, width: 88, height: 32)),
                SemanticNode(id: "cancel", role: .button, frame: Rect(x: 112, y: 48, width: 88, height: 32)),
            ]
        )
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: Fixture.context()
        )
        XCTAssertEqual(verdict.status, .pass, verdict.findings.map(\.message).joined(separator: "; "))
    }

    /// One planted defect per rule; each must be caught by exactly its own rule.
    func testEveryRuleCatchesItsPlantedDefect() {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Fixture.viewport,
            children: [
                SemanticNode(
                    id: "truncated",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 100, height: 20),
                    text: "Monthly summary",
                    textMetrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 2)
                ),
                SemanticNode(id: "vanished", role: .image, frame: Rect(x: 0, y: 30, width: 0, height: 0)),
                SemanticNode(id: "tiny", role: .button, frame: Rect(x: 0, y: 40, width: 20, height: 20)),
                SemanticNode(id: "lost", role: .button, frame: Rect(x: 900, y: 40, width: 40, height: 40)),
                SemanticNode(id: "under", role: .toggle, frame: Rect(x: 0, y: 100, width: 60, height: 40)),
                SemanticNode(id: "over", role: .toggle, frame: Rect(x: 40, y: 100, width: 60, height: 40)),
                SemanticNode(id: "under", role: .toggle, frame: Rect(x: 0, y: 200, width: 60, height: 40)),
            ]
        )
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: Fixture.context()
        )
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(
            Set(verdict.findings.map(\.rule)),
            ["duplicate-probe-id", "zero-size", "sibling-overlap", "offscreen", "truncation", "tap-target"]
        )
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "truncation" })?.nodeID, "truncated")
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "zero-size" })?.nodeID, "vanished")
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "tap-target" })?.nodeID, "tiny")
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "offscreen" })?.nodeID, "lost")
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "sibling-overlap" })?.nodeID, "over")
        XCTAssertEqual(verdict.findings.first(where: { $0.rule == "duplicate-probe-id" })?.nodeID, "under")
    }

    func testEveryStandardRuleShipsASuggestion() {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Fixture.viewport,
            children: [
                SemanticNode(
                    id: "truncated",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 100, height: 20),
                    textMetrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 2)
                ),
                SemanticNode(id: "vanished", role: .image, frame: Rect(x: 0, y: 30, width: 0, height: 0)),
                SemanticNode(id: "tiny", role: .button, frame: Rect(x: 0, y: 40, width: 20, height: 20)),
                SemanticNode(id: "lost", role: .button, frame: Rect(x: 900, y: 40, width: 40, height: 40)),
                SemanticNode(id: "under", role: .toggle, frame: Rect(x: 0, y: 100, width: 60, height: 40)),
                SemanticNode(id: "over", role: .toggle, frame: Rect(x: 40, y: 100, width: 60, height: 40)),
                SemanticNode(id: "under", role: .toggle, frame: Rect(x: 0, y: 200, width: 60, height: 40)),
            ]
        )
        let verdict = RuleEngine.run(rules: RuleEngine.standardRules, on: tree, context: Fixture.context())
        for finding in verdict.findings {
            XCTAssertNotNil(finding.suggestion, "\(finding.rule) must ship an actionable hint")
        }
    }
}
