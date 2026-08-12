import Foundation
import VerdictUIKernel

/// Joins the two channels, and decides what happens when only one of them ran.
///
/// ``Reconcile/compare(internalTree:externalTree:tolerance:)`` answers "do the
/// channels agree?" — but it can only be asked when there IS an external tree.
/// This type owns the question one level up: *the witness may not be able to
/// run at all*, and the caller asked for cross-validation anyway.
///
/// ### Why a failed witness is a finding rather than a thrown error
///
/// The in-process verdict is perfectly producible when the witness fails; only
/// its STRENGTH changes. Propagating the error would make the CLI exit 2 ("no
/// verdict could be produced"), which is false, and would throw away a verdict
/// the caller can use. Swallowing it would be worse: a caller that asked for
/// cross-validation and got an ordinary PASS reads it as "both channels agree"
/// when in fact one channel never ran. So the outcome is always a verdict, and
/// the verdict always says which of the two happened.
///
/// ### Why the trust flag is not the gate
///
/// `AXIsProcessTrusted()` reports what was GRANTED, never what is REACHABLE.
/// Measured 2026-08-12 (`docs/wave8-ax-findings.md` §3): it returned `true` in
/// every failing case — an untrusted-looking read failed with -25204 while the
/// flag said yes. A witness gating on the flag proceeds confidently onto an
/// empty tree, and an empty tree is indistinguishable at the point of use from
/// a scenario that genuinely renders nothing. So availability is decided by the
/// READ, and the flag only ever labels the reason after the fact.
public enum CrossValidation {

    /// Cross-validate `internalTree` against a witness read.
    ///
    /// - Parameters:
    ///   - internalTree: the in-process tree produced by the probes.
    ///   - tolerance: how far the channels may disagree before it is a finding.
    ///   - read: produces the external tree, or throws when it cannot.
    /// - Returns: reconciliation findings when the witness ran; exactly one
    ///   ``Reconcile/unavailableRule`` warning when it did not. Never throws.
    public static func findings(
        internalTree: SemanticNode,
        tolerance: Reconcile.Tolerance = .standard,
        read: () throws -> SemanticNode
    ) -> [Finding] {
        let externalTree: SemanticNode
        do {
            externalTree = try read()
        } catch {
            return [Reconcile.unavailable(reason: reason(for: error))]
        }
        return Reconcile.compare(
            internalTree: internalTree, externalTree: externalTree, tolerance: tolerance)
    }

    /// Cross-validate against a real windowed host running `scenario`.
    ///
    /// The convenience over ``findings(internalTree:tolerance:read:)`` that
    /// callers actually use; the closure form exists so the unavailable path is
    /// testable without revoking a real permission grant.
    public static func findings(
        internalTree: SemanticNode,
        scenario: String,
        host: WitnessHostProcess,
        tolerance: Reconcile.Tolerance = .standard
    ) -> [Finding] {
        findings(internalTree: internalTree, tolerance: tolerance) {
            try host.readTree(scenario: scenario)
        }
    }

    /// The human-readable reason carried into the skipped finding.
    ///
    /// A finding that says only "skipped" cannot be acted on — the fix for a
    /// missing permission grant and the fix for a host that never launched are
    /// different fixes, and the reader has no other source for which one they
    /// are looking at.
    ///
    /// Non-``AXReader/Failure`` errors are described rather than collapsed into
    /// a generic string: the witness reaches the OS through a launch path, so an
    /// error from Foundation is a real possibility, and its own description is
    /// more informative than anything this layer could substitute.
    static func reason(for error: any Error) -> String {
        (error as? AXReader.Failure)?.description ?? "\(error)"
    }
}
