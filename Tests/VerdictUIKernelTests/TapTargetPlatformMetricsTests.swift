// The `tap-target` threshold, checked against what macOS controls ACTUALLY
// measure rather than against a number copied from a touch platform.
//
// The Wave 10 fleet dogfood produced three `tap-target` errors on a SagaMail
// settings screen whose toggles are the size SwiftUI makes them. A survey of
// native control metrics — measured with
// `NSHostingView(rootView:).fittingSize`, outside VerdictUI entirely — settled
// why:
//
//     Toggle (switch)      60.0 x 18.0      Stepper            65.0 x 26.0
//     Toggle .checkbox     60.0 x 18.0      Slider             200.0 x 16.0
//     Button               54.0 x 24.0      TextField          200.0 x 24.0
//     Button .bordered     54.0 x 24.0      Picker             200.0 x 24.0
//     Menu                 94.0 x 24.0
//
// NOT ONE standard macOS control reaches 28 pt in height. The old threshold
// could therefore never distinguish "too small to hit" from "a macOS control",
// and it fired at ERROR severity on idiomatic SwiftUI written exactly as Apple
// ships it — the shape `no.md` #25 records as how a linter gets switched off
// rather than fixed.
//
// These tests pin the recalibration in BOTH directions. A threshold chosen to
// silence the dogfood would satisfy the first group alone; the second group is
// what makes it a rule instead.
import XCTest

@testable import VerdictUIKernel

final class TapTargetPlatformMetricsTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 420, height: 400)

    /// Builds a tree of one interactive leaf at the given size.
    private func control(
        _ id: String,
        width: Double,
        height: Double,
        role: Role = .button
    ) -> SemanticNode {
        SemanticNode(
            id: id,
            role: role,
            frame: Rect(x: 0, y: 0, width: width, height: height),
            structuralPath: "root/\(id)"
        )
    }

    private func findings(
        for node: SemanticNode,
        context: LintContext? = nil
    ) -> [Finding] {
        let ctx = context ?? LintContext.macOS(viewport: viewport, scenario: "metrics")
        return TapTargetRule().evaluate(
            SemanticNode(
                id: "root",
                role: .container,
                frame: viewport,
                structuralPath: "root",
                children: [node]
            ),
            context: ctx
        )
    }

    // MARK: - The platform's own controls must pass

    /// Every native macOS control, at its measured size, must be silent. These
    /// are not edge cases: they are what a correctly-written Mac app contains.
    func testEveryStandardMacOSControlSizeIsAccepted() {
        let measured: [(String, Double, Double)] = [
            ("toggle-switch", 60, 18),
            ("toggle-checkbox", 60, 18),
            ("button", 54, 24),
            ("button-bordered", 54, 24),
            ("menu", 94, 24),
            ("stepper", 65, 26),
            ("slider", 200, 16),
            ("textfield", 200, 24),
            ("picker", 200, 24),
        ]

        for (id, width, height) in measured {
            let hits = findings(for: control(id, width: width, height: height))
            XCTAssertTrue(
                hits.isEmpty,
                "'\(id)' at \(width)x\(height) pt is a NATIVE macOS control size and must not "
                    + "be reported: \(hits.map(\.message))"
            )
        }
    }

    /// `.controlSize(.mini)` is an explicit author choice, supported by the
    /// platform, and its 19x12 pt switch is the smallest thing SwiftUI will
    /// make on request. A rule that fires here is second-guessing an API.
    func testTheSmallestSupportedControlSizeIsAccepted() {
        let hits = findings(for: control("mini-toggle", width: 19, height: 12))
        XCTAssertTrue(
            hits.isEmpty,
            "a .controlSize(.mini) toggle (19x12 pt, measured) must not be reported: "
                + "\(hits.map(\.message))"
        )
    }

    // MARK: - The negative control: real defects must still fail

    /// The demo scenario's dismiss button, at the 6 x 6 pt it shrank to when the
    /// floor moved. If the recalibration swallowed this, the rule would have
    /// been deleted rather than fixed — so this is the assertion that separates
    /// a threshold change from a silencer.
    func testAGenuinelyUndersizedControlIsStillReported() {
        let hits = findings(for: control("dismiss-button", width: 6, height: 6))

        XCTAssertEqual(hits.count, 1, "a 6x6 pt control must still be reported")
        XCTAssertEqual(hits.first?.nodeID, "dismiss-button")
        XCTAssertEqual(
            hits.first?.severity, .error,
            "a control genuinely below the platform floor stays an error"
        )
    }

    /// A control narrow in ONE dimension only. Width and height are checked
    /// independently, so a 4 pt-wide button is a defect however tall it is.
    func testAControlUndersizedInOneDimensionOnlyIsReported() {
        let hits = findings(for: control("sliver", width: 4, height: 24))
        XCTAssertEqual(hits.count, 1, "a 4 pt-wide control must be reported")
    }

    /// The boundary itself, from both sides, so the threshold cannot drift
    /// without a test noticing.
    func testTheThresholdIsExactlyWhereItIsDocumented() {
        let minimum = LintContext.macOSMinimumTapTarget

        XCTAssertTrue(
            findings(for: control("at-minimum", width: minimum.width, height: minimum.height))
                .isEmpty,
            "a control exactly at the minimum passes"
        )
        XCTAssertFalse(
            findings(
                for: control("below", width: minimum.width, height: minimum.height - 0.5)
            ).isEmpty,
            "a control half a point below the minimum fails"
        )
    }

    // MARK: - Touch metrics are unchanged

    /// The touch minimum is a different platform's number and must NOT move
    /// with the macOS one. A scenario rendered at iOS metrics still polices
    /// 44x44, and a macOS-sized control fails there — which is correct, and is
    /// the whole reason the two contexts are separate.
    func testTouchMetricsStillPoliceTheLargerMinimum() {
        let touch = LintContext.touch(viewport: viewport, scenario: "metrics")

        XCTAssertEqual(LintContext.touchMinimumTapTarget, Size(width: 44, height: 44))
        XCTAssertFalse(
            findings(for: control("mac-button", width: 54, height: 24), context: touch).isEmpty,
            "a 24 pt-tall control is below the 44 pt TOUCH minimum and must be reported there"
        )
    }

    /// The two platforms must not have converged. If they ever agree, one of
    /// them is wrong, and `LintContext.touch` has silently stopped being a
    /// distinct policy.
    func testTheMacOSAndTouchMinimumsRemainDistinct() {
        XCTAssertNotEqual(
            LintContext.macOSMinimumTapTarget,
            LintContext.touchMinimumTapTarget,
            "the macOS and touch minimums collapsed into one — .touch is now a no-op"
        )
        XCTAssertLessThan(
            LintContext.macOSMinimumTapTarget.height,
            LintContext.touchMinimumTapTarget.height
        )
    }
}
