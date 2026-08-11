import XCTest

@testable import VerdictUIKernel

/// `inconsistent-spacing` catches the one gap that breaks a stack's rhythm.
///
/// Two properties decide whether this rule is usable, and both are pinned here
/// harder than the happy path: it must stay SILENT when no rhythm exists (a
/// deliberately varied layout is not a defect), and it must pick the rhythm by
/// MODE rather than mean, because a mean is dragged by the very outlier being
/// hunted and then reports every gap as slightly wrong.
final class InconsistentSpacingRuleTests: XCTestCase {
    private let rule = InconsistentSpacingRule()

    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 600)

    private func context() -> LintContext {
        LintContext(scenario: "inconsistent-spacing", viewport: Self.viewport)
    }

    private func root(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(id: "root", role: .container, frame: Self.viewport, children: children)
    }

    /// A vertical stack whose gaps are exactly `gaps`, each row 20 pt tall.
    /// Building the fixture from the gaps themselves keeps the intent visible:
    /// a test says `[12, 12, 20, 12]` and means it.
    private func verticalStack(gaps: [Double], height: Double = 20) -> [SemanticNode] {
        var nodes: [SemanticNode] = []
        var y = 0.0
        for index in 0...gaps.count {
            nodes.append(
                SemanticNode(
                    id: "row\(index)",
                    role: .text,
                    frame: Rect(x: 16, y: y, width: 200, height: height)
                )
            )
            if index < gaps.count { y += height + gaps[index] }
        }
        return nodes
    }

    // MARK: - The defect

    func testTheOneGapThatBreaksTheRhythmIsReported() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 20, 12])),
            context: context()
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.rule, "inconsistent-spacing")
        // The node AFTER the broken gap: it is the element that moved.
        XCTAssertEqual(findings.first?.nodeID, "row3")
        XCTAssertEqual(findings.first?.severity, .warning)
        XCTAssertEqual(
            findings.first?.message,
            "'row3' sits 20 pt below 'row2' but the other vertical gaps here are 12 pt"
        )
        XCTAssertNotNil(findings.first?.suggestion)
    }

    /// A row stack is measured on its own axis. A rule that always compared `y`
    /// would pass every vertically-written test and be blind to half its subject
    /// — every horizontal gap in a toolbar or button row.
    func testAHorizontalRhythmBreakIsReported() {
        var nodes: [SemanticNode] = []
        var x = 0.0
        for (index, gap) in [8.0, 8, 8, 24].enumerated() {
            nodes.append(
                SemanticNode(
                    id: "chip\(index)",
                    role: .button,
                    frame: Rect(x: x, y: 0, width: 40, height: 20)
                )
            )
            x += 40 + gap
        }
        nodes.append(
            SemanticNode(id: "chip4", role: .button, frame: Rect(x: x, y: 0, width: 40, height: 20))
        )

        let findings = rule.evaluate(root(nodes), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["chip4"])
        XCTAssertTrue(findings.first?.message.contains("horizontal") == true)
        XCTAssertTrue(findings.first?.message.contains("after") == true)
    }

    /// The mode, not the mean. With gaps `12, 12, 12, 12, 20` the mean is 13.6,
    /// so a mean-based rule reports ALL FIVE gaps as wrong — including the four
    /// that are correct — and the real outlier is buried in the noise.
    func testTheRhythmIsTheModeSoOnlyTheOutlierIsReported() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 12, 12, 20])),
            context: context()
        )

        XCTAssertEqual(findings.map(\.nodeID), ["row5"])
        XCTAssertTrue(
            findings.first?.message.contains("are 12 pt") == true,
            "the message must quote the modal gap, got: \(findings.first?.message ?? "none")"
        )
    }

    // MARK: - Silence where no rhythm exists

    /// The assertion that keeps this rule enable-able. A deliberately varied
    /// layout has no rhythm to break, and reporting its odd gap out would invent
    /// an intent the layout never expressed.
    func testALayoutWithNoDominantRhythmIsNotReported() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [8, 20, 33, 5])),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty, "no majority gap means no rhythm to violate")
    }

    /// Exactly half is not a majority: `12, 12, 30, 40` has two 12s out of four
    /// gaps, which is a tie between "rhythm" and "variety", not a rhythm.
    func testAModeHoldingExactlyHalfTheGapsIsNotARhythm() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 30, 40])),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    func testAnEvenlySpacedStackIsSilent() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 12, 12])),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    /// Float noise must not read as a rhythm break — otherwise the rule reports
    /// sub-pixel layout arithmetic on real trees constantly.
    func testSubPixelGapVariationIsToleratedButRealVariationIsNot() {
        let noise = rule.evaluate(
            root(verticalStack(gaps: [12, 12.25, 12, 11.8])),
            context: context()
        )
        XCTAssertTrue(noise.isEmpty, "quarter-point drift is arithmetic, not a defect")

        let real = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 12, 18])),
            context: context()
        )
        XCTAssertEqual(real.count, 1)
    }

    /// Too few gaps to establish anything: with two gaps, "the odd one out" is a
    /// coin toss between them.
    func testTooFewSiblingsToEstablishARhythmAreNotJudged() {
        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 30])),
            context: context()
        )

        XCTAssertTrue(findings.isEmpty)
    }

    // MARK: - Shapes with no single rhythm

    /// A grid has rows AND columns, so neither axis alone describes its spacing.
    /// Picking one and reporting whatever falls out would report every grid.
    func testAGridIsDeclinedRatherThanJudgedOnOneAxis() {
        let cells = (0..<4).map { index in
            SemanticNode(
                id: "cell\(index)",
                role: .container,
                frame: Rect(
                    x: Double(index % 2) * 100,
                    y: Double(index / 2) * 100,
                    width: 80,
                    height: 80
                )
            )
        }

        XCTAssertTrue(rule.evaluate(root(cells), context: context()).isEmpty)
    }

    /// Overlapping siblings are a `sibling-overlap` finding, not a spacing one.
    /// A stack requires each element to start after the previous one ends.
    func testOverlappingSiblingsAreNotTreatedAsAStack() {
        let overlapping = (0..<4).map { index in
            SemanticNode(
                id: "layer\(index)",
                role: .container,
                frame: Rect(x: 0, y: Double(index) * 5, width: 200, height: 100)
            )
        }

        XCTAssertTrue(rule.evaluate(root(overlapping), context: context()).isEmpty)
    }

    /// A spacer IS the gap. Including it would measure the distance to a gap
    /// rather than between the elements a user sees, so a `Spacer()` between two
    /// rows would read as a rhythm break in a layout behaving exactly as written.
    func testSpacersAreNotMeasuredAsElements() {
        var nodes = verticalStack(gaps: [12, 12, 12, 12])
        nodes.append(
            SemanticNode(id: "gap", role: .spacer, frame: Rect(x: 16, y: 300, width: 200, height: 60))
        )

        XCTAssertTrue(rule.evaluate(root(nodes), context: context()).isEmpty)
    }

    func testInvisibleAndUnplaceableNodesAreIgnored() {
        var nodes = verticalStack(gaps: [12, 12, 12, 12])
        nodes.append(
            SemanticNode(
                id: "hidden",
                role: .text,
                frame: Rect(x: 16, y: 400, width: 200, height: 20),
                isVisible: false
            )
        )
        nodes.append(
            SemanticNode(
                id: "broken",
                role: .text,
                frame: Rect(x: 16, y: 500, width: .nan, height: 20)
            )
        )

        XCTAssertTrue(rule.evaluate(root(nodes), context: context()).isEmpty)
    }

    /// A probe may emit children in any order; the rule sorts by position before
    /// measuring. Without that, an unsorted pass produces negative gaps that read
    /// as a broken rhythm in a perfectly even stack.
    func testChildrenEmittedOutOfLayoutOrderStillMeasureCorrectly() {
        let ordered = verticalStack(gaps: [12, 12, 12, 12])

        XCTAssertTrue(
            rule.evaluate(root(ordered.reversed()), context: context()).isEmpty,
            "an even stack must stay silent regardless of the order children arrive in"
        )
    }

    // MARK: - Rule-library contract

    func testSuppressionSilencesOnlyTheTaggedNode() {
        var nodes = verticalStack(gaps: [12, 12, 20, 12])
        nodes[3].attributes[LintContext.suppressionKey] = .string("inconsistent-spacing")

        XCTAssertTrue(rule.evaluate(root(nodes), context: context()).isEmpty)
    }

    func testSeverityOverrideIsHonoured() {
        var overridden = context()
        overridden.severityOverrides = ["inconsistent-spacing": .error]

        let findings = rule.evaluate(
            root(verticalStack(gaps: [12, 12, 20, 12])),
            context: overridden
        )

        XCTAssertEqual(findings.first?.severity, .error)
    }

    func testRuleIsRegisteredInTheStandardSet() {
        XCTAssertTrue(
            RuleEngine.standardRules.contains { type(of: $0).id == InconsistentSpacingRule.id },
            "a rule absent from standardRules never runs for any consumer"
        )
    }

    /// All three thresholds are public API, so their VALUES are part of the
    /// contract and a silent drift changes every consumer's verdict.
    ///
    /// `minimumRhythmShare` carries the load-bearing property: it must be at
    /// least one half, or a MINORITY gap could be crowned as the rhythm and
    /// every element following the real spacing would be reported instead of the
    /// outlier — the rule inverted, still green, still emitting findings.
    func testTheRhythmThresholdsArePinnedAndTheShareIsAMajority() {
        XCTAssertEqual(InconsistentSpacingRule.quantum, 0.5)
        XCTAssertEqual(InconsistentSpacingRule.minimumGapCount, 3)
        XCTAssertEqual(InconsistentSpacingRule.minimumRhythmShare, 0.5)
        XCTAssertGreaterThanOrEqual(
            InconsistentSpacingRule.minimumRhythmShare,
            0.5,
            "below a majority a minority gap can be crowned as the rhythm, and the rule "
                + "reports every correctly-spaced element instead of the outlier"
        )
    }

    // MARK: - The rhythm helper, directly

    func testRhythmIsDeterministicUnderTies() {
        // Two 10s and two 20s: no majority, so no rhythm — and the answer must
        // not depend on dictionary iteration order, which is not stable across
        // runs and would make the rule impossible to baseline.
        for _ in 0..<20 {
            XCTAssertNil(InconsistentSpacingRule.rhythm(of: [10, 10, 20, 20]))
        }
    }

    func testRhythmReportsAGapThatActuallyOccurs() {
        // Quantization buckets 12.0 and 12.2 together; the reported rhythm is
        // their mean, so the message quotes a value the layout really contains
        // rather than a rounded bucket key.
        let rhythm = InconsistentSpacingRule.rhythm(of: [12.0, 12.2, 12.1, 30])

        XCTAssertNotNil(rhythm)
        XCTAssertEqual(try XCTUnwrap(rhythm), 12.1, accuracy: 0.2)
    }
}
