// Wave 7: the serializable form of an act.
//
// `StepResult` is the harness's own value and is deliberately not made
// `Codable`: it carries two whole `SemanticNode` trees plus a `SettleResult`
// whose `settled(after: Duration)` payload has no stable JSON form. Encoding it
// directly would put a full before-tree AND a full after-tree on the wire for
// every act — several KB per step, against a 300 B budget — which is the exact
// cost the delta exists to avoid.
//
// So the wire form carries the DELTA (compacted) plus the verdict, and offers
// the after-tree only when a caller asks for it.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// The result of one act, as it appears on the wire.
public struct StepResultWire: Codable, Sendable, Equatable {
    /// Probe the action targeted.
    public let probe: String
    /// PASS or FAIL, from the step's verdict.
    public let status: String
    /// What changed, in the compact form.
    public let delta: CompactDelta
    /// Findings the after-tree produced. Carried in full rather than counted:
    /// a step that reports "3 findings" and makes the agent call `verify` to
    /// learn what they were has spent a round trip to save a few bytes.
    public let findings: [Finding]
    /// Whether the UI went quiet before the deadline.
    ///
    /// A separate field rather than an inference from `findings`, because a
    /// timed-out settle and a lint failure are different claims: the first says
    /// the observation may be incomplete, and an agent that read a timeout as a
    /// layout defect would go fix the wrong thing.
    public let settled: Bool
    /// Wall-clock milliseconds the whole act took.
    public let elapsedMs: Double
    /// The after-tree, only when the caller asked for it.
    public let tree: CompactTree?

    public init(
        probe: String,
        status: String,
        delta: CompactDelta,
        findings: [Finding],
        settled: Bool,
        elapsedMs: Double,
        tree: CompactTree? = nil
    ) {
        self.probe = probe
        self.status = status
        self.delta = delta
        self.findings = findings
        self.settled = settled
        self.elapsedMs = elapsedMs
        self.tree = tree
    }

    /// Convert a harness step to its wire form.
    ///
    /// - Parameter includeTree: also carry the after-tree. Off by default; see
    ///   ``DaemonRequest/includeTree``.
    public init(_ step: StepResult, includeTree: Bool = false) {
        self.probe = step.probeID
        self.status = step.verdict.status.rawValue
        self.delta = CompactDelta(step.delta)
        self.findings = step.verdict.findings
        if case .settled = step.settle {
            self.settled = true
        } else {
            self.settled = false
        }
        self.elapsedMs = step.elapsedMs
        // `after` is nil only when the before-capture failed, in which case
        // there is no after-tree to send and the findings already say why.
        self.tree = includeTree ? step.after.map { CompactTree($0) } : nil
    }
}
