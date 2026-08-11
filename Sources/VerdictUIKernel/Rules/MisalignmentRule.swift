// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Sibling edges that are ALMOST aligned are worse than edges that are not.
///
/// The "2 px off" class: two labels in a form whose leading edges sit at 16 and
/// 18 pt, a button whose trailing edge misses the field above it by 3 pt. A
/// human reads it instantly as sloppy; no existing rule can see it, because
/// every frame is the size it asked for and nothing overlaps, clips or leaves
/// the viewport.
///
/// ## Why a near-miss is the defect and a wide gap is not
///
/// Alignment is a claim about intent. Edges 2 pt apart are the author intending
/// alignment and missing — a stray `.padding(2)`, a hard-coded offset, an icon
/// whose baked-in whitespace differs from its sibling's. Edges 40 pt apart are a
/// deliberate indent, a nested hierarchy, a two-column layout. So the rule fires
/// on a NON-ZERO deviation strictly below ``alignmentTolerance`` and is silent
/// both at exact alignment and at any honest distance.
///
/// That window is what makes the rule safe to enable by default. A rule that
/// fired on every unaligned edge would report most of every real screen, which
/// is how a lint library loses its users.
///
/// ## Choosing the tolerance by measurement, not taste
///
/// 4 pt. The value has to sit above the float noise the layout engine itself
/// produces and below the smallest deliberate inset a designer would author.
/// SwiftUI's own spacing vocabulary starts at 4 pt and its default padding is 16
/// pt; sub-pixel layout arithmetic lands within the 0.5 pt band the overlap
/// rules already use. A deviation of 1-3 pt is therefore too large to be
/// rounding and too small to be an inset — it can only be a mistake. At 4 pt and
/// above the rule cannot distinguish a small deliberate offset from a large
/// mistake, so it says nothing rather than guessing.
///
/// Severity is `warning`: the kernel cannot prove the author wanted alignment,
/// and a near-miss is a strong smell rather than a proof. Suppress per node with
/// `attributes["verdict.suppress"] = .string("misalignment")`.
public struct MisalignmentRule: LintRule {
    public static let id = "misalignment"

    /// Deviations at or above this are read as deliberate spacing, not a miss.
    /// See the type's discussion for why the value is 4 and not a preference.
    public static let alignmentTolerance = 4.0

    /// Below this, two edges are the same edge — float noise from layout
    /// arithmetic, the same band ``SiblingOverlapRule/tolerance`` treats as
    /// noise. Spelled independently on purpose: that constant answers "do these
    /// rectangles collide", this one answers "are these edges the same", and
    /// collapsing them would couple two rules that happen to share a number.
    public static let coincidenceTolerance = 0.5

    /// The four edges compared, each with the name a finding reports.
    ///
    /// Modelled as an enum rather than four near-identical code paths so a fifth
    /// edge (a baseline, once the probe supplies one) is one case, and so the
    /// message wording cannot drift between edges.
    ///
    /// Deliberately an enum with a `value(of:)` method rather than a struct
    /// holding a `(Rect) -> Double` closure: a closure is not `Sendable`, so a
    /// `static let` array of them is rejected outright under this package's
    /// complete strict-concurrency setting. ``LintRule`` is `Sendable` precisely
    /// so the Wave 6 daemon can hold one rule set and evaluate trees
    /// concurrently, and a rule smuggling non-`Sendable` state into a static
    /// would defeat that for every rule in the set.
    enum Edge: String, CaseIterable, Sendable {
        case leading
        case trailing
        case top
        case bottom

        /// The name a finding reports for this edge.
        var name: String { rawValue }

        /// This edge's coordinate on `rect`.
        func value(of rect: Rect) -> Double {
            switch self {
            case .leading: rect.x
            case .trailing: rect.maxX
            case .top: rect.y
            case .bottom: rect.maxY
            }
        }
    }

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var findings: [Finding] = []
        for parent in root.flattened() {
            let siblings = parent.children.filter(Self.isEligible)
            guard siblings.count > 1 else { continue }

            for index in siblings.indices.dropFirst() {
                guard
                    let miss = Self.worstMiss(
                        for: siblings[index],
                        against: siblings[..<index]
                    )
                else { continue }

                let finding = context.makeFinding(
                    rule: Self.id,
                    node: siblings[index],
                    message: miss.message,
                    suggestion: "align the \(miss.edge.name) edges exactly, or separate them by "
                        + "at least \(Self.alignmentTolerance.pointsDescription) pt so the "
                        + "offset reads as deliberate",
                    defaultSeverity: .warning
                )
                if let finding { findings.append(finding) }
            }
        }
        return findings
    }

    /// One node's near-miss against the siblings laid out before it.
    struct Miss {
        let edge: Edge
        let message: String
    }

    /// The single worst near-miss `node` makes against any earlier sibling, or
    /// `nil` when it is aligned or honestly separated on every edge.
    ///
    /// ## Why one finding per NODE and not one per edge
    ///
    /// A box nudged 2 pt sideways misses on `leading` AND `trailing` at once —
    /// same width, so both edges shift together — and a box nudged down misses
    /// `top` and `bottom`. Reporting per edge therefore doubles every real
    /// defect, and measured on the first draft it did exactly that:
    /// `["right", "right"]`, `["sloppy", "sloppy"]`. One displaced element is
    /// one defect, so the node reports once, naming its worst edge.
    ///
    /// ## Why an exact alignment silences the node
    ///
    /// A node aligned with ANY earlier sibling on a given edge has satisfied the
    /// intent for that edge, so a near-miss against a third, sloppier sibling is
    /// that sibling's defect and not this node's. Without this, one stray
    /// element makes every correctly-aligned row around it report.
    private static func worstMiss(
        for node: SemanticNode,
        against earlier: ArraySlice<SemanticNode>
    ) -> Miss? {
        var worst: (deviation: Double, miss: Miss)?

        for edge in Edge.allCases {
            let value = edge.value(of: node.frame)
            var nearest: (deviation: Double, reference: SemanticNode)?

            for candidate in earlier {
                let reference = edge.value(of: candidate.frame)
                let deviation = abs(value - reference)

                // Exactly aligned with someone — this edge is satisfied.
                if deviation <= coincidenceTolerance {
                    nearest = nil
                    break
                }
                // Far enough apart to be a deliberate inset; this pair says
                // nothing, but a nearer sibling still might.
                guard deviation < alignmentTolerance else { continue }
                if deviation < (nearest?.deviation ?? .infinity) {
                    nearest = (deviation, candidate)
                }
            }

            guard let nearest else { continue }
            guard nearest.deviation > (worst?.deviation ?? -.infinity) else { continue }

            let reference = edge.value(of: nearest.reference.frame)
            worst = (
                nearest.deviation,
                Miss(
                    edge: edge,
                    message: "'\(node.evidenceLabel)' misses \(edge.name) alignment with "
                        + "'\(nearest.reference.evidenceLabel)' by "
                        + "\(nearest.deviation.pointsDescription) pt "
                        + "(\(value.pointsDescription) vs \(reference.pointsDescription))"
                )
            )
        }

        return worst?.miss
    }

    /// Nodes whose geometry can carry an alignment claim.
    ///
    /// Spacers are excluded because their edges are wherever the layout pushed
    /// them — a spacer is a gap, and a gap has no intended alignment. Invisible
    /// and unplaceable nodes are excluded for the reasons every rule excludes
    /// them: nothing renders there to be misaligned.
    private static func isEligible(_ node: SemanticNode) -> Bool {
        node.isVisible && !node.frame.isEmpty && node.role != .spacer
    }
}
