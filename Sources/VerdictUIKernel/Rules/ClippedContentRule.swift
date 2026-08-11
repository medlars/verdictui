// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Content must not extend past the container that holds it.
///
/// A row whose label is 40 pt wider than the card around it, a button pushed
/// below the bottom of its panel, an image overflowing a fixed-height header.
/// SwiftUI does not clip by default, so the content is often still VISIBLE —
/// which is why this is not the same defect as ``TruncationRule``, and why it is
/// invisible to every other rule: nothing overlaps a sibling, nothing leaves the
/// viewport, nothing is zero-sized, and the text lost no characters. The element
/// simply escaped its box.
///
/// The consequence is real either way. If the ancestor clips (`.clipped()`, a
/// `List` row, a `ScrollView` viewport) the overflow is silently cut off; if it
/// does not, the content paints over whatever the parent's layout reserved for
/// something else. Both are defects, and the geometry that predicts them is the
/// same.
///
/// ## Why containment is checked against ANCESTORS, not just the parent
///
/// A label inside an `HStack` inside a card overflows the CARD while sitting
/// comfortably inside its immediate parent — the `HStack` grew to fit its child
/// and pushed the problem up a level. Checking only the parent misses exactly
/// the case that reaches a user. So each leaf is checked against every ancestor
/// and reports the OUTERMOST one it escapes, which is the box a human sees the
/// content burst out of.
///
/// ## Why the root and the viewport are excluded
///
/// ``OffscreenRule`` owns content leaving the viewport, and the root node IS the
/// viewport. Reporting both would produce two findings, in two vocabularies, for
/// one escape — and this rule's message ("escapes its container") would be the
/// less accurate of the two.
///
/// Severity is `error`: unlike a wrap or a near-miss, escaping a container has
/// no reading under which the author meant it. Suppress per node with
/// `attributes["verdict.suppress"] = .string("clipped-content")`.
public struct ClippedContentRule: LintRule {
    public static let id = "clipped-content"

    /// Overflow below this is float noise from layout arithmetic — a child whose
    /// rounded frame sits a quarter-point past its parent's is not escaping it.
    /// The same band the other geometry rules treat as noise, for the reason
    /// ``SiblingOverlapRule/tolerance`` documents.
    public static let tolerance = 0.5

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var findings: [Finding] = []
        // The root is the viewport; `offscreen` owns escapes from it.
        for child in root.children {
            collect(child, ancestors: [], context: context, into: &findings)
        }
        return findings
    }

    private func collect(
        _ node: SemanticNode,
        ancestors: [SemanticNode],
        context: LintContext,
        into findings: inout [Finding]
    ) {
        if Self.isEligible(node), let escaped = Self.outermostEscaped(by: node, among: ancestors) {
            let overflow = Self.overflow(of: node.frame, beyond: escaped.frame)
            if let finding = context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' extends \(overflow.amount.pointsDescription) pt "
                    + "past the \(overflow.edge) edge of '\(escaped.evidenceLabel)'",
                suggestion: "give '\(escaped.evidenceLabel)' room for its content, or constrain "
                    + "'\(node.evidenceLabel)' with .frame(maxWidth:) or .lineLimit() so it "
                    + "fits inside",
                defaultSeverity: .error
            ) {
                findings.append(finding)
            }
        }

        let chain = Self.isEligible(node) ? ancestors + [node] : ancestors
        for child in node.children {
            collect(child, ancestors: chain, context: context, into: &findings)
        }
    }

    /// The outermost ancestor `node` escapes, or `nil` if it fits inside all of
    /// them.
    ///
    /// `ancestors` is ordered root-first, so the first escape found is the
    /// outermost box the content bursts out of — the one a human sees.
    private static func outermostEscaped(
        by node: SemanticNode,
        among ancestors: [SemanticNode]
    ) -> SemanticNode? {
        ancestors.first { escapes(node.frame, from: $0.frame) }
    }

    /// Whether `inner` extends beyond `outer` on any edge by more than the
    /// tolerance.
    ///
    /// Deliberately not `Rect.contains`: that answers a strict containment
    /// question with no tolerance, so a child one float-ulp past its parent
    /// would report. Here the question is "did this escape by an amount a human
    /// could see", which needs the same noise band the sibling rules use.
    static func escapes(_ inner: Rect, from outer: Rect) -> Bool {
        guard !inner.isEmpty, !outer.isEmpty else { return false }
        return inner.x < outer.x - tolerance
            || inner.y < outer.y - tolerance
            || inner.maxX > outer.maxX + tolerance
            || inner.maxY > outer.maxY + tolerance
    }

    /// The worst single overflow of `inner` past `outer`, with the edge's name.
    ///
    /// One number and one edge, not four: a box that escapes on two edges is one
    /// escaped box, and the largest overflow is the one that describes it.
    static func overflow(of inner: Rect, beyond outer: Rect) -> (edge: String, amount: Double) {
        let candidates: [(String, Double)] = [
            ("leading", outer.x - inner.x),
            ("top", outer.y - inner.y),
            ("trailing", inner.maxX - outer.maxX),
            ("bottom", inner.maxY - outer.maxY),
        ]
        // `max(by:)` over a fixed-order array is deterministic under ties, which
        // a baselined verdict requires.
        let worst = candidates.max { $0.1 < $1.1 }
        return (worst?.0 ?? "trailing", max(worst?.1 ?? 0, 0))
    }

    /// Nodes whose geometry can make or break a containment claim.
    ///
    /// Spacers are excluded in both roles: a spacer is a gap, and a gap
    /// overflowing its container is the container's layout doing its job.
    private static func isEligible(_ node: SemanticNode) -> Bool {
        node.isVisible && !node.frame.isEmpty && node.role != .spacer
    }
}
