// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

extension Rect {
    /// Compact `x,y WxH` rendering used inside reconciliation messages.
    ///
    /// Internal, and deliberately not a `CustomStringConvertible` conformance:
    /// `Rect` crosses the JSON boundary, and giving a wire type a `description`
    /// invites it into a message where a caller then parses it back.
    var shortDescription: String {
        "\(x.pointsDescription),\(y.pointsDescription) "
            + "\(width.pointsDescription)x\(height.pointsDescription)"
    }
}

/// Compares the in-process semantic tree against an external witness tree and
/// reports where the two channels disagree.
///
/// This is the machinery behind "how do we know the probes aren't lying?" — the
/// fast channel (Layout-protocol probes) is checked against a channel that
/// shares none of its code: the accessibility tree the window server actually
/// publishes. A probe that misreports its frame agrees with itself forever; it
/// cannot agree with AX.
///
/// Deliberately NOT a ``LintRule``. Every rule in `Rules/` evaluates ONE tree,
/// and widening that protocol to carry an optional second tree would make every
/// existing rule declare an argument it never reads. A comparator is a
/// different shape of thing, so it gets a different entry point.
public enum Reconcile {
    /// Rule identifier for a node the probe reported that the external channel
    /// cannot see.
    public static let visibilityGapRule = "ax-visibility-gap"
    /// Rule identifier for a node both channels see but disagree about.
    public static let disagreementRule = "ax-disagreement"
    /// Rule identifier reported when cross-validation could not run at all.
    public static let unavailableRule = "cross-validation-skipped"

    /// How far the two channels may disagree before it counts as a defect.
    ///
    /// Frames are compared with a tolerance because the channels measure at
    /// different moments through different machinery: AX reports integral
    /// device-aligned geometry while the layout pass works in fractional
    /// points, so a half-point difference is the two channels agreeing, not
    /// disagreeing. The default is deliberately tight enough that a genuinely
    /// wrong frame — the deliberate-lie fixtures plant whole-point errors —
    /// cannot hide inside it.
    public struct Tolerance: Equatable, Sendable {
        /// Maximum per-edge frame difference, in points, that still counts as agreement.
        public var frameEpsilon: Double

        public init(frameEpsilon: Double = 1.0) {
            self.frameEpsilon = frameEpsilon
        }

        /// The default tolerance: 1 pt per edge.
        public static let standard = Tolerance()
    }

    /// Compare the two channels and return one finding per disagreement.
    ///
    /// Matching is by ``SemanticNode/id`` when the probe supplied one and by
    /// ``SemanticNode/structuralPath`` otherwise — the same identity rule
    /// ``TreeDiff`` uses, so a node that survives a diff is the same node the
    /// reconciler talks about.
    ///
    /// - Parameters:
    ///   - internalTree: the in-process tree produced by the probes.
    ///   - externalTree: the witness tree normalized from `AXUIElement`.
    ///   - tolerance: how far frames may differ before it is a finding.
    /// - Returns: findings, empty when the channels agree.
    public static func compare(
        internalTree: SemanticNode,
        externalTree: SemanticNode,
        tolerance: Tolerance = .standard
    ) -> [Finding] {
        // Index the external side once. The external channel has no probe ids —
        // AX does not carry them — so it is keyed on structural path, and the
        // internal side is matched down to the same path.
        var external: [String: SemanticNode] = [:]
        for node in externalTree.flattened() where !node.structuralPath.isEmpty {
            external[node.structuralPath] = node
        }

        var findings: [Finding] = []
        for node in internalTree.flattened() {
            // Only nodes that claim to render are reconcilable. An invisible or
            // empty node is legitimately absent from AX, and reporting it would
            // make every hidden scaffold a finding — noise that would train the
            // reader to ignore this rule entirely.
            guard node.isVisible, !node.frame.isEmpty else { continue }
            // A spacer occupies space and renders nothing, so AX never publishes
            // it. That is correct behaviour on both sides, not a gap.
            guard node.role != .spacer else { continue }

            guard let match = external[node.structuralPath] else {
                findings.append(
                    Finding(
                        rule: visibilityGapRule,
                        severity: .warning,
                        nodeID: node.evidenceLabel,
                        message: "'\(node.evidenceLabel)' (\(node.role.identifier)) is reported by "
                            + "the probe at \(node.frame.shortDescription) but is absent from the "
                            + "accessibility tree",
                        suggestion: node.role.isInteractive
                            ? "add an accessibility label so assistive technology can reach this "
                                + "control, e.g. .accessibilityLabel(\"…\")"
                            : "if this element is decorative, mark it "
                                + ".accessibilityHidden(true) to make the omission explicit"
                    )
                )
                continue
            }

            findings.append(
                contentsOf: disagreements(internal: node, external: match, tolerance: tolerance)
            )
        }
        return findings
    }

    /// The per-node comparison: role, frame, text.
    private static func disagreements(
        internal node: SemanticNode,
        external match: SemanticNode,
        tolerance: Tolerance
    ) -> [Finding] {
        var findings: [Finding] = []

        if node.role != match.role {
            findings.append(
                Finding(
                    rule: disagreementRule,
                    severity: .error,
                    nodeID: node.evidenceLabel,
                    message: "'\(node.evidenceLabel)' is \(node.role.identifier) in the probe tree "
                        + "but \(match.role.identifier) in the accessibility tree",
                    suggestion: "the probe's role classification disagrees with what the platform "
                        + "publishes; one of the two is wrong about what this element is"
                )
            )
        }

        if let edge = frameDisagreement(node.frame, match.frame, epsilon: tolerance.frameEpsilon) {
            findings.append(
                Finding(
                    rule: disagreementRule,
                    severity: .error,
                    nodeID: node.evidenceLabel,
                    message: "'\(node.evidenceLabel)' \(edge) — probe reports "
                        + "\(node.frame.shortDescription), accessibility reports "
                        + "\(match.frame.shortDescription)",
                    suggestion: "the probe's geometry does not match what the window server "
                        + "renders; a verdict computed from the probe frame is unsound here"
                )
            )
        }

        // Text is compared only when BOTH channels carry it. AX omits text for
        // roles it models as unlabeled, and treating that as a mismatch would
        // report a finding about the accessibility vocabulary rather than about
        // the UI. The absent-label case is already covered by the visibility gap.
        if let mine = node.text, let theirs = match.text, mine != theirs {
            findings.append(
                Finding(
                    rule: disagreementRule,
                    severity: .error,
                    nodeID: node.evidenceLabel,
                    message: "'\(node.evidenceLabel)' reads \"\(mine)\" in the probe tree but "
                        + "\"\(theirs)\" in the accessibility tree",
                    suggestion: "the text the probe reports is not the text the platform exposes; "
                        + "assistive technology and the verdict disagree about this element"
                )
            )
        }

        return findings
    }

    /// Names the first edge that differs by more than `epsilon`, or `nil` when
    /// the two frames agree.
    ///
    /// Returns a NAME rather than a bool so the finding can say which edge moved
    /// — "x differs by 12 pt" is actionable where "frames differ" sends the
    /// reader back to compare four numbers by hand.
    static func frameDisagreement(_ mine: Rect, _ theirs: Rect, epsilon: Double) -> String? {
        // A non-finite component cannot be compared: every comparison against
        // NaN is false, so a tolerance check would report agreement for a frame
        // that is not a frame. Report it rather than silently passing.
        guard mine.x.isFinite, mine.y.isFinite, mine.width.isFinite, mine.height.isFinite,
            theirs.x.isFinite, theirs.y.isFinite, theirs.width.isFinite, theirs.height.isFinite
        else {
            return "has a non-finite frame component"
        }
        for (name, a, b) in [
            ("x", mine.x, theirs.x),
            ("y", mine.y, theirs.y),
            ("width", mine.width, theirs.width),
            ("height", mine.height, theirs.height),
        ] where abs(a - b) > epsilon {
            return "\(name) differs by \((a - b).magnitude.pointsDescription) pt"
        }
        return nil
    }

    /// The finding returned when cross-validation could not run.
    ///
    /// A warning rather than an error, and never silence: a caller that asked
    /// for cross-validation and got an ordinary PASS would read it as "both
    /// channels agree" when in fact only one channel ran. The verdict says which
    /// happened.
    public static func unavailable(reason: String) -> Finding {
        Finding(
            rule: unavailableRule,
            severity: .warning,
            nodeID: "",
            message: "cross-validation skipped: \(reason)",
            suggestion: "this verdict reflects the in-process channel only; it is not "
                + "cross-validated"
        )
    }
}
