import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// Task 3 (SD6): the permission path.
///
/// The property under test is narrow and load-bearing: a caller that ASKED for
/// cross-validation and could not get it must receive a verdict that SAYS so.
/// The failure this guards against is not a crash — it is a silently weaker
/// PASS, where "the channels agree" and "only one channel ran" arrive at the
/// caller as the same answer.
///
/// Every test here pairs with a control. "Emits a warning when the witness is
/// unavailable" is satisfied by an implementation that emits the warning
/// unconditionally, so each availability test has a working-reader sibling that
/// asserts the warning is ABSENT (`no.md` #17: a predicate whose tests only
/// exercise one branch cannot distinguish a working rule from an always-true
/// one).
final class CrossValidationTests: XCTestCase {

    // MARK: - Fixtures

    /// A two-node tree the reconciler can actually compare.
    private func probeTree() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    frame: Rect(x: 10, y: 10, width: 80, height: 20),
                    text: "Settings"
                )
            ]
        ).withAssignedStructuralPaths()
    }

    /// A witness tree that agrees with ``probeTree()`` exactly.
    private func agreeingTree() -> SemanticNode { probeTree() }

    // MARK: - The unavailable path

    func testAFailedReadBecomesAWarningFindingNamingTheReason() {
        let findings = CrossValidation.findings(
            internalTree: probeTree(),
            read: { throw AXReader.Failure.notTrusted }
        )

        let skipped = findings.filter { $0.rule == Reconcile.unavailableRule }
        XCTAssertEqual(
            skipped.count, 1,
            "a witness that could not run must produce exactly one skipped finding")
        XCTAssertEqual(
            skipped.first?.severity, .warning,
            "cross-validation being unavailable is a warning about the VERDICT's strength, not "
                + "an error about the UI under test")
        // The reason must survive into the message. A finding that says only
        // "skipped" cannot be acted on: the fix for a missing permission grant
        // and the fix for a host that never launched are different fixes.
        XCTAssertTrue(
            skipped.first?.message.contains("Accessibility permission") == true,
            "the finding must name WHY, got: \(skipped.first?.message ?? "<none>")")
    }

    func testEveryReaderFailureModeProducesTheSkippedFinding() {
        // Enumerated rather than sampled: `AXReader.Failure` is the witness's
        // whole error vocabulary, and a case handled by falling through to an
        // ordinary PASS is exactly the silent-weakening this task exists to
        // prevent. A new case added later without a branch here fails this test.
        let failures: [AXReader.Failure] = [
            .notTrusted,
            .noWindow(axError: -25204),
            .hostUnavailable("the host process never appeared"),
            .anchorUnreadable,
        ]
        for failure in failures {
            let findings = CrossValidation.findings(
                internalTree: probeTree(), read: { throw failure })
            XCTAssertEqual(
                findings.filter { $0.rule == Reconcile.unavailableRule }.count, 1,
                "\(failure) did not produce a skipped finding")
        }
    }

    func testAnUnexpectedErrorStillProducesTheSkippedFindingRatherThanPropagating() {
        struct Unexpected: Error {}
        // The witness reads through the OS. An error that is not an
        // `AXReader.Failure` — a Foundation error from the launch path, say —
        // must still be reported as "cross-validation did not run", never
        // escape as a thrown error the CLI would render as exit 2. Exit 2 means
        // "no verdict could be produced", and the in-process verdict here is
        // perfectly producible.
        let findings = CrossValidation.findings(
            internalTree: probeTree(), read: { throw Unexpected() })

        XCTAssertEqual(findings.filter { $0.rule == Reconcile.unavailableRule }.count, 1)
    }

    // MARK: - The control: a working witness must NOT report itself unavailable

    func testAWorkingWitnessProducesNoSkippedFinding() {
        // The negative control. Without it, `findings` could return the skipped
        // warning on every call and every test above would still pass — the
        // always-true predicate shape.
        let findings = CrossValidation.findings(
            internalTree: probeTree(),
            read: { self.agreeingTree() }
        )

        XCTAssertTrue(
            findings.allSatisfy { $0.rule != Reconcile.unavailableRule },
            "a witness that RAN must not report itself unavailable; got \(findings)")
        XCTAssertTrue(
            findings.isEmpty,
            "the two channels agree, so there is nothing to report; got \(findings)")
    }

    func testAWorkingWitnessStillReportsRealDisagreements() {
        // The other half of the control: proving the skipped finding is absent
        // is worth nothing if the comparison itself was skipped too. A witness
        // that RAN and DISAGREED must produce the disagreement.
        var lying = probeTree()
        lying.children[0].frame = Rect(x: 10, y: 10, width: 80, height: 20)
        let witness = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    // 40 pt to the right of where the probe claims.
                    frame: Rect(x: 50, y: 10, width: 80, height: 20),
                    text: "Settings"
                )
            ]
        ).withAssignedStructuralPaths()

        let findings = CrossValidation.findings(internalTree: lying, read: { witness })

        XCTAssertTrue(
            findings.contains { $0.rule == Reconcile.disagreementRule },
            "a planted frame disagreement was not reported; got \(findings)")
        XCTAssertTrue(
            findings.allSatisfy { $0.rule != Reconcile.unavailableRule },
            "the witness ran, so it must not also claim to have been skipped")
    }

    // MARK: - The trust flag is a label, never the gate

    func testTheTrustFlagIsNotConsultedAsAGate() throws {
        // `docs/wave8-ax-findings.md` §3: `AXIsProcessTrusted()` returned true in
        // every failing case measured. So a witness gating on the flag proceeds
        // confidently onto an empty tree, and a witness REFUSING on the flag
        // would skip on machines where the read works fine.
        //
        // This asserts the consequence rather than the predicate: with a reader
        // that succeeds, the result must be a real comparison REGARDLESS of what
        // the flag says on this machine. Asserting `isTrusted == false` would
        // pass whichever way the branch goes (`no.md` #15).
        let findings = CrossValidation.findings(
            internalTree: probeTree(), read: { self.agreeingTree() })

        XCTAssertTrue(
            findings.isEmpty,
            "the comparison must run on its own merits, not on the trust flag "
                + "(isTrusted = \(AXReader.isTrusted) on this machine)")
    }
}
