// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A container that occupies space must contain something that renders.
///
/// The defect this catches is a data-driven view whose content failed to arrive:
/// a `List` whose `ForEach` got an empty array, a detail pane bound to a `nil`
/// selection, a card whose body threw away its children behind a condition that
/// was never true. The container still lays out — padding and a background give
/// it real area — so nothing else in the rule library can see it. ``ZeroSizeRule``
/// is silent by construction because the frame is not zero, and every other rule
/// iterates children the container does not have.
///
/// It is the container analogue of the ``RuleEngine/vacuousVerdictRule`` guard:
/// area without content reads to a human as "the screen is broken", and to the
/// engine as nothing at all.
///
/// ## What this rule can and cannot claim
///
/// It reports a container that HAS children none of which paint. It says nothing
/// about a CHILDLESS container, because from the layout pass a probed leaf that
/// paints itself (a filled shape, a capsule background, a divider) is
/// indistinguishable from a container whose content never arrived — both have
/// zero children, and no attribute in the tree records whether a node draws.
/// Closing that gap needs a paint signal from the probe, the same missing data
/// that defers `ContrastRule`; until it exists, silence is the honest answer and
/// the nested case is the one worth reporting anyway, since the real defect
/// emits its wrapper (an empty `ForEach` still hosts, a false branch still
/// wraps).
///
/// ## Why area is required, and why a bare `spacer` child does not count
///
/// A zero-area container is normal — collapsed disclosure groups, conditional
/// branches that correctly rendered nothing, `EmptyView` hosts. Firing on those
/// would report the ordinary case constantly, which is how a rule gets disabled
/// wholesale. The defect is specifically area RESERVED and not filled, so the
/// rule requires a frame larger than ``minimumReportableArea`` on both axes.
///
/// A subtree of nothing but ``Role/spacer`` nodes is treated as empty for the
/// same reason: a `VStack { Spacer() }` where the content was meant to be
/// renders exactly the blank box this rule exists to name. Spacers occupy space
/// and render nothing — that is their documented job — so counting them as
/// content would make the rule unable to fire on the commonest spelling of the
/// defect.
///
/// Severity is `warning`, not `error`: a deliberately blank spacer-driven layout
/// region is legitimate (a flexible gap given a background), and the kernel
/// cannot read intent. Suppress per node with
/// `attributes["verdict.suppress"] = .string("empty-container")`.
public struct EmptyContainerRule: LintRule {
    public static let id = "empty-container"

    /// Below this on either axis, a container is too small to be a visible
    /// blank region and is not reported.
    ///
    /// Spelled as a static rather than a ``LintContext`` knob, matching
    /// ``SiblingOverlapRule/tolerance``: no caller has asked to tune it, and
    /// widening a public type's shape for a speculative knob is a cost paid by
    /// every consumer. The value is a whole point rather than the 0.5 pt float
    /// tolerance the overlap rules use, because this is not a float-noise
    /// threshold — it is a claim about what a human can see.
    public static let minimumReportableArea = 1.0

    /// Container roles this rule polices.
    ///
    /// Restricted to roles whose entire job is holding content. A ``Role/button``
    /// with no children is not a defect (its label may live in `text`), an
    /// ``Role/image`` has no children by nature, and a ``Role/custom(_:)`` role
    /// means the probe could not classify the node — reporting an unclassified
    /// node as an empty container states more than the tree supports.
    static let policedRoles: Set<String> = [
        Role.container.identifier,
        Role.list.identifier,
        Role.listRow.identifier,
    ]

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var findings: [Finding] = []
        collect(root, context: context, into: &findings)
        return findings
    }

    /// Preorder walk that reports the OUTERMOST empty container on each branch
    /// and does not descend past it.
    ///
    /// A blank `VStack { HStack { } }` is one defect, not two. Reporting every
    /// empty node on the chain turns an N-deep wrapper into N findings for a
    /// single blank region, and a rule that multiplies its own evidence is how a
    /// backlog stops being readable. The outermost node is also the one an
    /// author fixes: it names the whole region a human sees blank, whereas the
    /// innermost names a wrapper that is merely the deepest symptom.
    private func collect(
        _ node: SemanticNode,
        context: LintContext,
        into findings: inout [Finding]
    ) {
        if Self.isReportable(node) {
            if let finding = context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' reserves "
                    + "\(node.frame.width.pointsDescription) x "
                    + "\(node.frame.height.pointsDescription) pt but renders nothing",
                suggestion: "render a placeholder or empty state for this container, or "
                    + "collapse it when it has no content",
                defaultSeverity: .warning
            ) {
                findings.append(finding)
                // Reported the whole region; its empty descendants are the same
                // defect. Note this returns only when a finding was actually
                // produced -- a SUPPRESSED node keeps descending, so suppressing
                // a wrapper reveals the empty child inside it rather than
                // silently hiding a subtree the author never named.
                return
            }
        }
        for child in node.children {
            collect(child, context: context, into: &findings)
        }
    }

    /// Whether `node` is itself a policed container reserving visible area with
    /// nothing rendering inside it.
    private static func isReportable(_ node: SemanticNode) -> Bool {
        guard node.isVisible else { return false }
        guard policedRoles.contains(node.role.identifier) else { return false }

        // A CHILDLESS container is not evidence of anything. From the layout
        // pass a probed leaf that paints itself — a `RoundedRectangle` fill, a
        // capsule background, a `Color`, a divider — is INDISTINGUISHABLE from a
        // container whose content failed to arrive: both have zero children, and
        // nothing in the tree says whether the node draws. `isVisible` is
        // hardcoded `true` by the probe and no paint attribute exists.
        //
        // Measured, not assumed: the first version of this rule reported
        // `card-surface` and `card-pill` in `CleanSettingsScenario` — the
        // reference CORRECT UI whose whole job is to produce zero findings. A
        // rule that fires on the clean scenario is the false-positive class that
        // gets a lint library switched off wholesale.
        //
        // What the tree CAN support is the nested case: a container that HAS
        // children, none of which paint. That is unambiguous — the author put
        // something inside and nothing came out — and it is also the shape the
        // real defect takes (a `ForEach` over an empty array still emits its
        // host, a conditional branch still emits its wrapper).
        guard !node.children.isEmpty else { return false }

        // `isEmpty` also covers the non-finite frames Rect documents; a
        // container that cannot be placed is a different defect and
        // `zero-size` owns it.
        guard !node.frame.isEmpty else { return false }
        guard node.frame.width > minimumReportableArea,
            node.frame.height > minimumReportableArea
        else { return false }

        return !rendersAnything(node)
    }

    /// Whether any descendant of `node` actually paints.
    ///
    /// Deliberately recursive rather than a `children.isEmpty` check: the defect
    /// wraps as often as not (`VStack { HStack { } }`), and a container holding
    /// one empty container is exactly as blank as one holding nothing.
    ///
    /// The distinction that makes it work is between a child that PAINTS and a
    /// child that merely OCCUPIES: a `text` or `image` is content by existing,
    /// but a container is content only if something inside it paints. Accepting
    /// any visible non-spacer box as content — the obvious spelling, and the
    /// first one written here — makes a wrapper around a blank box look filled,
    /// so the outer node is never reported and only the innermost wrapper is.
    /// Measured before it was fixed: `VStack { HStack { } }` reported `inner`
    /// alone, naming the deepest symptom instead of the blank region.
    private static func rendersAnything(_ node: SemanticNode) -> Bool {
        for child in node.children {
            guard child.isVisible, !child.frame.isEmpty else { continue }
            // A spacer occupies space and renders nothing, by definition.
            if child.role == .spacer { continue }
            // A container is a vessel: it paints only what it holds. Anything
            // else — text, image, button, an unclassified custom role — is
            // content in its own right, so its mere presence fills the parent.
            if policedRoles.contains(child.role.identifier) {
                if rendersAnything(child) { return true }
                continue
            }
            return true
        }
        return false
    }
}
