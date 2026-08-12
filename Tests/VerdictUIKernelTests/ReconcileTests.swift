import XCTest

@testable import VerdictUIKernel

/// Tests for the cross-validation reconciler.
///
/// Every assertion that a disagreement IS reported is paired with a control
/// proving the same shape stays silent when the channels agree. Without the
/// control, "reports a frame mismatch" is satisfied by a reconciler that
/// reports a frame mismatch for every node it ever sees — the always-true rule
/// `no.md` #17 names, which reads as working and enforces nothing.
final class ReconcileTests: XCTestCase {

    // MARK: - Fixtures

    /// A node with a structural path, which is the key both channels match on.
    private func node(
        id: String = "",
        role: Role,
        frame: Rect,
        text: String? = nil,
        path: String,
        isVisible: Bool = true,
        children: [SemanticNode] = []
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: role,
            frame: frame,
            text: text,
            isVisible: isVisible,
            structuralPath: path,
            children: children
        )
    }

    private func pair(
        internalChild: SemanticNode,
        externalChild: SemanticNode
    ) -> (SemanticNode, SemanticNode) {
        let root = Rect(x: 0, y: 0, width: 200, height: 200)
        return (
            node(role: .container, frame: root, path: "root", children: [internalChild]),
            node(role: .container, frame: root, path: "root", children: [externalChild])
        )
    }

    // MARK: - Agreement (the control for every test below)

    func testIdenticalTreesProduceNoFindings() {
        let frame = Rect(x: 10, y: 20, width: 80, height: 30)
        let (mine, theirs) = pair(
            internalChild: node(id: "save", role: .button, frame: frame, text: "Save", path: "root/button[0]"),
            externalChild: node(role: .button, frame: frame, text: "Save", path: "root/button[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertTrue(
            findings.isEmpty,
            "channels that agree must produce no findings, got: \(findings.map(\.message))"
        )
    }

    // MARK: - Frame disagreement

    func testFrameDisagreementBeyondToleranceIsReported() {
        // The probe claims the button sits at x=10; the platform renders it at
        // x=50. This is the planted-lie shape the honesty proof rests on.
        let (mine, theirs) = pair(
            internalChild: node(
                id: "save", role: .button,
                frame: Rect(x: 10, y: 20, width: 80, height: 30), path: "root/button[0]"),
            externalChild: node(
                role: .button,
                frame: Rect(x: 50, y: 20, width: 80, height: 30), path: "root/button[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertEqual(findings.count, 1, "one disagreement, one finding")
        let finding = try? XCTUnwrap(findings.first)
        XCTAssertEqual(finding?.rule, Reconcile.disagreementRule)
        XCTAssertEqual(finding?.severity, .error, "a lying probe is a defect, not a note")
        // The message must name the EDGE and the measurement. A finding reading
        // "frames differ" makes the reader diff four numbers by hand.
        XCTAssertTrue(
            finding?.message.contains("x differs by 40 pt") == true,
            "message must name the edge and the amount, got: \(finding?.message ?? "nil")"
        )
        XCTAssertEqual(finding?.nodeID, "save")
    }

    func testSubPointFrameDifferenceIsAgreement() {
        // The control that stops the rule above being always-true. AX reports
        // device-aligned geometry while layout works in fractional points, so a
        // half-point difference is the two channels AGREEING.
        let (mine, theirs) = pair(
            internalChild: node(
                id: "save", role: .button,
                frame: Rect(x: 10.4, y: 20.3, width: 80.2, height: 30.1), path: "root/button[0]"),
            externalChild: node(
                role: .button,
                frame: Rect(x: 10, y: 20, width: 80, height: 30), path: "root/button[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertTrue(
            findings.isEmpty,
            "sub-point differences are measurement noise, not defects: \(findings.map(\.message))"
        )
    }

    func testToleranceBoundaryIsExclusive() {
        // Exactly at the epsilon must PASS; beyond it must FAIL. Pinning both
        // sides stops the comparison silently becoming >= or <=.
        let epsilon = Reconcile.Tolerance.standard.frameEpsilon
        XCTAssertNil(
            Reconcile.frameDisagreement(
                Rect(x: 0, y: 0, width: 10, height: 10),
                Rect(x: epsilon, y: 0, width: 10, height: 10),
                epsilon: epsilon
            ),
            "a difference of exactly epsilon is agreement"
        )
        XCTAssertNotNil(
            Reconcile.frameDisagreement(
                Rect(x: 0, y: 0, width: 10, height: 10),
                Rect(x: epsilon * 2, y: 0, width: 10, height: 10),
                epsilon: epsilon
            ),
            "a difference beyond epsilon is a disagreement"
        )
    }

    func testNonFiniteFrameIsReportedRatherThanSilentlyPassing() {
        // Every comparison against NaN is false, so a plain tolerance check
        // reports AGREEMENT for a frame that is not a frame — silence on
        // exactly the shape a broken layout produces.
        let edge = Reconcile.frameDisagreement(
            Rect(x: .nan, y: 0, width: 10, height: 10),
            Rect(x: 0, y: 0, width: 10, height: 10),
            epsilon: 1.0
        )
        XCTAssertEqual(edge, "has a non-finite frame component")
    }

    // MARK: - Role disagreement

    func testRoleDisagreementIsReported() {
        let frame = Rect(x: 10, y: 20, width: 80, height: 30)
        let (mine, theirs) = pair(
            internalChild: node(id: "ctl", role: .button, frame: frame, path: "root/x[0]"),
            externalChild: node(role: .toggle, frame: frame, path: "root/x[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .error)
        XCTAssertTrue(
            findings.first?.message.contains("button") == true
                && findings.first?.message.contains("toggle") == true,
            "message must name BOTH roles so the reader knows which channel to doubt"
        )
    }

    // MARK: - Text disagreement

    func testTextDisagreementIsReported() {
        let frame = Rect(x: 10, y: 20, width: 80, height: 30)
        let (mine, theirs) = pair(
            internalChild: node(id: "t", role: .text, frame: frame, text: "Save", path: "root/t[0]"),
            externalChild: node(role: .text, frame: frame, text: "Delete", path: "root/t[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings.first?.message.contains("\"Save\"") == true)
        XCTAssertTrue(findings.first?.message.contains("\"Delete\"") == true)
    }

    func testTextAbsentFromExternalChannelIsNotADisagreement() {
        // AX omits text for roles it models as unlabeled. Reporting that as a
        // mismatch produces a finding about the accessibility vocabulary rather
        // than about the UI — the always-fires shape, one layer along.
        let frame = Rect(x: 10, y: 20, width: 80, height: 30)
        let (mine, theirs) = pair(
            internalChild: node(id: "t", role: .text, frame: frame, text: "Save", path: "root/t[0]"),
            externalChild: node(role: .text, frame: frame, text: nil, path: "root/t[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertTrue(findings.isEmpty, "an absent external label is not a text mismatch")
    }

    // MARK: - Visibility gaps

    func testProbedNodeAbsentFromAccessibilityTreeIsAGap() {
        let (mine, theirs) = pair(
            internalChild: node(
                id: "ghost", role: .button,
                frame: Rect(x: 10, y: 20, width: 80, height: 30), path: "root/button[0]"),
            // External channel has a DIFFERENT path — the node is simply not there.
            externalChild: node(
                role: .text, frame: Rect(x: 0, y: 0, width: 5, height: 5), path: "root/other[9]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        let gaps = findings.filter { $0.rule == Reconcile.visibilityGapRule }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.nodeID, "ghost")
        XCTAssertEqual(
            gaps.first?.severity, .warning,
            "an AX gap is an accessibility finding, not proof the layout is wrong"
        )
        // The free accessibility audit: an unreachable CONTROL gets the label fix-it.
        XCTAssertTrue(
            gaps.first?.suggestion?.contains("accessibilityLabel") == true,
            "an interactive gap must suggest the label that would close it"
        )
    }

    func testInvisibleAndEmptyNodesAreNotReportedAsGaps() {
        // The control for the test above. Hidden scaffolding is legitimately
        // absent from AX; reporting it would bury the real gaps in noise.
        let root = node(
            role: .container, frame: Rect(x: 0, y: 0, width: 200, height: 200), path: "root",
            children: [
                node(
                    id: "hidden", role: .button, frame: Rect(x: 1, y: 1, width: 40, height: 40),
                    path: "root/button[0]", isVisible: false),
                node(
                    id: "empty", role: .button, frame: Rect(x: 1, y: 1, width: 0, height: 0),
                    path: "root/button[1]"),
                node(
                    id: "gap", role: .spacer, frame: Rect(x: 1, y: 1, width: 10, height: 10),
                    path: "root/spacer[2]"),
            ]
        )
        let external = node(
            role: .container, frame: Rect(x: 0, y: 0, width: 200, height: 200), path: "root")

        let findings = Reconcile.compare(internalTree: root, externalTree: external)

        XCTAssertTrue(
            findings.isEmpty,
            "invisible, empty and spacer nodes are correctly absent from AX: "
                + "\(findings.map(\.message))"
        )
    }

    // MARK: - Unavailability

    func testUnavailableProducesAWarningThatNamesTheReason() {
        // A caller that asked for cross-validation and got an ordinary PASS
        // would read it as "both channels agree" when only one channel ran.
        let finding = Reconcile.unavailable(reason: "no Accessibility permission")

        XCTAssertEqual(finding.rule, Reconcile.unavailableRule)
        XCTAssertEqual(finding.severity, .warning)
        XCTAssertTrue(finding.message.contains("no Accessibility permission"))
        XCTAssertTrue(
            finding.suggestion?.contains("not") == true,
            "the suggestion must say the verdict is NOT cross-validated"
        )
    }

    // MARK: - Multiple disagreements

    func testEachDisagreementIsReportedSeparately() {
        // One node wrong in three ways yields three findings, so a fix list is
        // a list of facts rather than one message the reader must decompose.
        let (mine, theirs) = pair(
            internalChild: node(
                id: "x", role: .button, frame: Rect(x: 0, y: 0, width: 80, height: 30),
                text: "Save", path: "root/x[0]"),
            externalChild: node(
                role: .toggle, frame: Rect(x: 40, y: 0, width: 80, height: 30),
                text: "Delete", path: "root/x[0]")
        )

        let findings = Reconcile.compare(internalTree: mine, externalTree: theirs)

        XCTAssertEqual(findings.count, 3, "role, frame and text each get their own finding")
        XCTAssertEqual(Set(findings.map(\.rule)), [Reconcile.disagreementRule])
    }
}
