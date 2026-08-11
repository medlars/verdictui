import XCTest

@testable import VerdictUIKernel

/// Expectations answer the question rules cannot: "is this the screen I meant?"
///
/// The load-bearing property is that an expectation can FAIL FOR ABSENCE. A
/// predicate whose subject is missing has nothing to check, and the tempting
/// reading — no node, no findings — turns a renamed probe into a green no-op
/// that silently stops testing anything. That is the vacuity shape
/// `RuleEngine.vacuousVerdictRule` guards at tree level, arriving one layer
/// down, so both halves are pinned here: a missing SUBJECT and a missing
/// COUNTERPART in a relational predicate.
final class ExpectationsTests: XCTestCase {
    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context() -> LintContext {
        LintContext(scenario: "expectations", viewport: Self.viewport)
    }

    /// Cancel at x 16-96, Save at x 112-192 — Save is right of Cancel, both on
    /// the same row, so the relational and alignment predicates have a real
    /// subject to agree or disagree about.
    private func tree(
        saveText: String? = "Save",
        saveFrame: Rect = Rect(x: 112, y: 200, width: 80, height: 32),
        saveVisible: Bool = true,
        saveAttributes: [String: AttributeValue] = [:],
        saveRole: Role = .button
    ) -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: Self.viewport,
            children: [
                SemanticNode(
                    id: "cancel-button",
                    role: .button,
                    frame: Rect(x: 16, y: 200, width: 80, height: 32),
                    text: "Cancel"
                ),
                SemanticNode(
                    id: "save-button",
                    role: saveRole,
                    frame: saveFrame,
                    text: saveText,
                    attributes: saveAttributes,
                    isVisible: saveVisible
                ),
            ]
        )
    }

    // MARK: - The satisfied case

    func testAFullySatisfiedExpectationProducesNoFindings() {
        let findings = Expectation("save-button")
            .visible
            .enabled
            .text("Save")
            .role(.button)
            .rightOf("cancel-button")
            .aligned(.top, with: "cancel-button")
            .width(.atLeast(80))
            .height(.exactly(32))
            .evaluate(in: tree(), context: context())

        XCTAssertTrue(findings.isEmpty, "got: \(findings.map(\.message))")
    }

    // MARK: - Absence is the finding

    /// A renamed or never-probed subject must not read as "nothing to report".
    func testAMissingSubjectIsAnErrorRatherThanSilence() {
        let findings = Expectation("submit-button")
            .visible
            .text("Submit")
            .evaluate(in: tree(), context: context())

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .error)
        XCTAssertEqual(findings.first?.rule, "expectation")
        XCTAssertEqual(
            findings.first?.message,
            "expected 'submit-button' but no such element is in the tree"
        )
        XCTAssertNotNil(findings.first?.suggestion)
    }

    /// The other half: the subject exists but the thing it is measured against
    /// does not. "rightOf a node that is not there" cannot be true or false, and
    /// answering either states more than the tree supports.
    func testAMissingRelationalCounterpartIsReported() {
        let findings = Expectation("save-button")
            .rightOf("nonexistent-button")
            .evaluate(in: tree(), context: context())

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(
            findings.first?.message,
            "'save-button' was expected to the right of 'nonexistent-button', "
                + "which is not in the tree"
        )
    }

    // MARK: - Predicates that must fail when the screen is wrong

    func testTextMismatchQuotesBothStrings() {
        let findings = Expectation("save-button")
            .text("Submit")
            .evaluate(in: tree(), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'save-button' reads \"Save\" but was expected to read \"Submit\""
        )
    }

    /// A node with no text at all must read as `no text`, not as an empty pair
    /// of quotes that looks like a real empty string.
    func testAbsentTextIsDescribedAsAbsence() {
        let findings = Expectation("save-button")
            .text("Save")
            .evaluate(in: tree(saveText: nil), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'save-button' reads no text but was expected to read \"Save\""
        )
    }

    func testInvisibilityIsReported() {
        let findings = Expectation("save-button")
            .visible
            .evaluate(in: tree(saveVisible: false), context: context())

        XCTAssertEqual(findings.map(\.message), ["'save-button' is not visible"])
    }

    func testADisabledControlIsReported() {
        let findings = Expectation("save-button")
            .enabled
            .evaluate(in: tree(saveAttributes: ["enabled": .bool(false)]), context: context())

        XCTAssertEqual(findings.map(\.message), ["'save-button' is disabled"])
    }

    /// The probe records `enabled` only for controls that can be disabled, so
    /// demanding the attribute would fail every element with no such state.
    func testAnElementWithNoEnabledAttributeCountsAsEnabled() {
        XCTAssertTrue(
            Expectation("save-button").enabled.evaluate(in: tree(), context: context()).isEmpty
        )
    }

    /// `textContains` is the predicate for text an author only partly controls
    /// — a count, a name, an interpolated value — so it must match a substring
    /// and reject a string that merely looks similar.
    func testTextContainsMatchesASubstringAndRejectsAMiss() {
        let satisfied = Expectation("save-button")
            .textContains("av")
            .evaluate(in: tree(), context: context())
        XCTAssertTrue(satisfied.isEmpty)

        let missed = Expectation("save-button")
            .textContains("Submit")
            .evaluate(in: tree(), context: context())
        XCTAssertEqual(
            missed.first?.message,
            "'save-button' reads \"Save\" which does not contain \"Submit\""
        )

        // A node with no text contains nothing, and must say so rather than
        // reporting an empty-string match.
        let absent = Expectation("save-button")
            .textContains("Save")
            .evaluate(in: tree(saveText: nil), context: context())
        XCTAssertEqual(
            absent.first?.message,
            "'save-button' reads no text which does not contain \"Save\""
        )
    }

    func testRoleMismatchIsReported() {
        let findings = Expectation("save-button")
            .role(.button)
            .evaluate(in: tree(saveRole: .text), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'save-button' is a text but was expected to be a button"
        )
    }

    func testAFailedRelationNamesTheCounterpart() {
        // Save moved to the far left, so it is no longer right of Cancel.
        let findings = Expectation("save-button")
            .rightOf("cancel-button")
            .evaluate(
                in: tree(saveFrame: Rect(x: 0, y: 200, width: 80, height: 32)),
                context: context()
            )

        XCTAssertEqual(
            findings.map(\.message),
            ["'save-button' is not to the right of 'cancel-button'"]
        )
    }

    /// Every relational direction, each with the geometry that satisfies it and
    /// the geometry that does not — a direction implemented backwards passes its
    /// own positive case, so the negative is what discriminates.
    func testEveryRelationalDirectionDiscriminates() {
        let reference = Rect(x: 100, y: 100, width: 50, height: 50)

        func check(
            _ build: (Expectation) -> Expectation,
            satisfiedBy: Rect,
            violatedBy: Rect,
            _ label: String
        ) {
            func evaluate(_ frame: Rect) -> [Finding] {
                let subject = SemanticNode(id: "subject", role: .container, frame: frame)
                let other = SemanticNode(id: "other", role: .container, frame: reference)
                let root = SemanticNode(
                    id: "root",
                    role: .container,
                    frame: Self.viewport,
                    children: [subject, other]
                )
                return build(Expectation("subject")).evaluate(in: root, context: context())
            }

            XCTAssertTrue(evaluate(satisfiedBy).isEmpty, "\(label) should hold")
            XCTAssertEqual(evaluate(violatedBy).count, 1, "\(label) should fail")
        }

        check({ $0.rightOf("other") },
            satisfiedBy: Rect(x: 160, y: 100, width: 20, height: 20),
            violatedBy: Rect(x: 20, y: 100, width: 20, height: 20), "rightOf")
        check({ $0.leftOf("other") },
            satisfiedBy: Rect(x: 20, y: 100, width: 20, height: 20),
            violatedBy: Rect(x: 160, y: 100, width: 20, height: 20), "leftOf")
        check({ $0.above("other") },
            satisfiedBy: Rect(x: 100, y: 20, width: 20, height: 20),
            violatedBy: Rect(x: 100, y: 160, width: 20, height: 20), "above")
        check({ $0.below("other") },
            satisfiedBy: Rect(x: 100, y: 160, width: 20, height: 20),
            violatedBy: Rect(x: 100, y: 20, width: 20, height: 20), "below")
        check({ $0.contained(in: "other") },
            satisfiedBy: Rect(x: 110, y: 110, width: 20, height: 20),
            violatedBy: Rect(x: 90, y: 110, width: 20, height: 20), "contained")
    }

    /// All four edges of the public ``MisalignmentRule/Edge`` vocabulary, each
    /// asserted through `aligned(_:with:)` in both directions.
    ///
    /// Public because expectations take one, so each case is API a consumer can
    /// name — and an edge whose accessor returns the wrong coordinate would pass
    /// any test that only ever checked one of them.
    func testEveryAlignmentEdgeDiscriminates() {
        let reference = Rect(x: 100, y: 100, width: 50, height: 50)

        func evaluate(_ edge: MisalignmentRule.Edge, _ frame: Rect) -> [Finding] {
            let root = SemanticNode(
                id: "root",
                role: .container,
                frame: Self.viewport,
                children: [
                    SemanticNode(id: "subject", role: .container, frame: frame),
                    SemanticNode(id: "other", role: .container, frame: reference),
                ]
            )
            return Expectation("subject")
                .aligned(edge, with: "other")
                .evaluate(in: root, context: context())
        }

        // Each edge is satisfied by a frame sharing THAT edge and violated by
        // one that shares a different edge — so an accessor returning the wrong
        // coordinate fails rather than coinciding.
        let cases: [(MisalignmentRule.Edge, Rect, Rect)] = [
            (.leading, Rect(x: 100, y: 200, width: 20, height: 20),
                Rect(x: 130, y: 200, width: 20, height: 20)),
            (.trailing, Rect(x: 130, y: 200, width: 20, height: 20),
                Rect(x: 100, y: 200, width: 20, height: 20)),
            (.top, Rect(x: 200, y: 100, width: 20, height: 20),
                Rect(x: 200, y: 130, width: 20, height: 20)),
            (.bottom, Rect(x: 200, y: 130, width: 20, height: 20),
                Rect(x: 200, y: 100, width: 20, height: 20)),
        ]

        for (edge, satisfied, violated) in cases {
            XCTAssertTrue(evaluate(edge, satisfied).isEmpty, "\(edge.name) should hold")
            XCTAssertEqual(evaluate(edge, violated).count, 1, "\(edge.name) should fail")
            XCTAssertEqual(edge.name, edge.rawValue)
        }
    }

    // MARK: - Dimensions

    func testEveryDimensionConstraintDiscriminates() {
        XCTAssertTrue(DimensionConstraint.exactly(80).isSatisfied(by: 80))
        XCTAssertTrue(DimensionConstraint.exactly(80).isSatisfied(by: 80.25))
        XCTAssertFalse(DimensionConstraint.exactly(80).isSatisfied(by: 82))

        XCTAssertTrue(DimensionConstraint.atLeast(80).isSatisfied(by: 80))
        XCTAssertFalse(DimensionConstraint.atLeast(80).isSatisfied(by: 79))

        XCTAssertTrue(DimensionConstraint.atMost(80).isSatisfied(by: 80))
        XCTAssertFalse(DimensionConstraint.atMost(80).isSatisfied(by: 81))

        XCTAssertTrue(DimensionConstraint.between(40, 80).isSatisfied(by: 60))
        XCTAssertFalse(DimensionConstraint.between(40, 80).isSatisfied(by: 90))
        XCTAssertFalse(DimensionConstraint.between(40, 80).isSatisfied(by: 30))
    }

    /// `.nan` compares false against every bound, so an unplaceable frame would
    /// slip through `atMost` by accident of IEEE semantics rather than by being
    /// correct. Every constraint must reject a non-finite measurement outright.
    func testANonFiniteMeasurementSatisfiesNoConstraint() {
        let constraints: [DimensionConstraint] = [
            .exactly(80), .atLeast(80), .atMost(80), .between(40, 80),
        ]
        for constraint in constraints {
            XCTAssertFalse(constraint.isSatisfied(by: .nan), "\(constraint) accepted NaN")
            XCTAssertFalse(constraint.isSatisfied(by: .infinity), "\(constraint) accepted inf")
        }
    }

    func testAWidthFailureQuotesBothTheMeasurementAndTheBound() {
        let findings = Expectation("save-button")
            .width(.atLeast(120))
            .evaluate(in: tree(), context: context())

        XCTAssertEqual(
            findings.first?.message,
            "'save-button' is 80 pt wide, expected at least 120 pt"
        )
    }

    // MARK: - Reporting shape

    /// Every predicate is evaluated rather than stopping at the first failure:
    /// an author fixing a screen wants the whole list, not one problem per
    /// verify cycle.
    func testAllFailingPredicatesAreReportedNotJustTheFirst() {
        let findings = Expectation("save-button")
            .text("Submit")
            .width(.atLeast(200))
            .role(.textField)
            .evaluate(in: tree(), context: context())

        XCTAssertEqual(findings.count, 3)
    }

    func testSuppressionOnTheNodeSilencesItsExpectations() {
        let suppressed = tree(
            saveAttributes: [LintContext.suppressionKey: .string("expectation")]
        )

        let findings = Expectation("save-button")
            .text("Submit")
            .evaluate(in: suppressed, context: context())

        XCTAssertTrue(findings.isEmpty)
    }

    /// A missing subject must NOT be silenceable, because the element carrying
    /// the suppression attribute is the one that is absent — there is nothing to
    /// read the directive from, and honouring an absent node's markup would let
    /// a deleted element hide its own deletion.
    func testAMissingSubjectCannotBeSuppressed() {
        var suppressEverything = context()
        suppressEverything.severityOverrides = ["expectation": .warning]

        let findings = Expectation("gone")
            .visible
            .evaluate(in: tree(), context: suppressEverything)

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(
            findings.first?.severity,
            .error,
            "a missing subject is an error regardless of overrides — there is no node to "
                + "carry a suppression directive, so the override must not reach it"
        )
    }

    // MARK: - Sets

    func testASetEvaluatesEveryExpectationInDeclarationOrder() {
        let set = ExpectationSet(
            "settings — logged out",
            [
                Expectation("cancel-button").text("Cancel"),
                Expectation("save-button").text("Submit"),
                Expectation("missing-button").visible,
            ]
        )

        let findings = set.evaluate(in: tree(), context: context())

        XCTAssertEqual(findings.map(\.nodeID), ["save-button", "missing-button"])
        XCTAssertEqual(set.name, "settings — logged out")
    }

    func testAnEmptySetReportsNothing() {
        XCTAssertTrue(
            ExpectationSet("empty", []).evaluate(in: tree(), context: context()).isEmpty
        )
    }
}
