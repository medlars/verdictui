// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Content that collides with content under a different parent.
///
/// ``SiblingOverlapRule`` compares children of one parent, which is the right
/// scope for its message ("give the siblings disjoint frames") — one container
/// owns the fix. It is therefore blind by construction to the most common real
/// overflow: a `Text` that outgrows its row and covers the *next* row's text.
/// Those two texts have different parents, so no single container's layout can
/// resolve the collision, and nothing reported it.
///
/// This rule closes that gap without widening the other one. It compares only
/// **leaf content** — nodes that render something — and only across **unrelated
/// branches**, which keeps three structural relationships silent:
/// - a node and its own ancestors (every child overlaps its parent),
/// - direct siblings (already ``SiblingOverlapRule``'s jurisdiction — reporting
///   them here would bill the same defect twice),
/// - containers themselves (two overlapping rows with disjoint content is a
///   background band or a grouped header, not a defect).
///
/// Deliberate layering is honoured exactly as ``SiblingOverlapRule`` honours it,
/// but checked along the whole ancestor path rather than at one node: a
/// ``SemanticNode/zIndex`` anywhere on either path, or a shared `zstack`
/// ancestor, means the author arranged the paint order on purpose.
///
/// Suppress per node with `attributes["verdict.suppress"] = .string("content-overlap")`.
public struct ContentOverlapRule: LintRule {
    public static let id = "content-overlap"

    /// Overlap below this is float noise from layout arithmetic, not a defect.
    /// Matches the tolerance ``TruncationRule`` applies to the same class of
    /// noise, so the two rules do not disagree about what "touching" means.
    public static let tolerance = 0.5

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        // Each entry keeps the node's ancestor chain (root first, node last) so
        // ancestry, sibling-ness and declared layering are all answered from the
        // path rather than re-walked per pair.
        var contents: [(node: SemanticNode, path: [SemanticNode])] = []
        Self.collectContent(root, path: [], into: &contents)

        var findings: [Finding] = []
        for lower in contents.indices {
            for upper in contents.indices where upper > lower {
                let first = contents[lower]
                let second = contents[upper]
                guard Self.isCrossBranch(first.path, second.path) else { continue }
                guard !Self.declaresLayering(first.path), !Self.declaresLayering(second.path) else {
                    continue
                }
                guard let overlap = first.node.frame.intersection(second.node.frame) else { continue }
                // A shared edge or a hairline of float noise is not a collision.
                guard overlap.width > Self.tolerance, overlap.height > Self.tolerance else { continue }

                let finding = context.makeFinding(
                    rule: Self.id,
                    node: second.node,
                    message: "'\(second.node.evidenceLabel)' overlaps "
                        + "'\(first.node.evidenceLabel)' by "
                        + "\(overlap.width.pointsDescription) x "
                        + "\(overlap.height.pointsDescription) pt — the two have different "
                        + "parents, so no single container's layout can resolve it",
                    suggestion: "give the containing rows enough height for their content, or "
                        + "truncate the overflowing content so it stays inside its row",
                    defaultSeverity: .error
                )
                if let finding { findings.append(finding) }
            }
        }
        return findings
    }

    /// Leaf content nodes, in preorder, each with its ancestor path.
    ///
    /// A container is skipped as a *subject* but still walked, and still appears
    /// in its descendants' paths — that is what makes the layering and ancestry
    /// checks able to see it.
    private static func collectContent(
        _ node: SemanticNode,
        path: [SemanticNode],
        into result: inout [(node: SemanticNode, path: [SemanticNode])]
    ) {
        let ownPath = path + [node]
        if node.children.isEmpty {
            if isRenderedContent(node) { result.append((node, ownPath)) }
        } else {
            for child in node.children {
                collectContent(child, path: ownPath, into: &result)
            }
        }
    }

    /// True for a leaf that actually paints something at a placeable size.
    /// A ``Role/spacer`` occupies space and renders nothing, so crossing one is
    /// not a collision between two visible things.
    private static func isRenderedContent(_ node: SemanticNode) -> Bool {
        node.isVisible && !node.frame.isEmpty && node.role != .spacer
    }

    /// True when the two nodes sit on genuinely different branches: neither is an
    /// ancestor of the other, and they are not direct siblings.
    ///
    /// Both paths start at the same root, so the shared prefix is their common
    /// ancestry. Equal path lengths with a shared prefix of `count - 1` means one
    /// parent holds both — ``SiblingOverlapRule``'s case, not this rule's.
    /// Internal rather than private: through ``evaluate`` only leaves become
    /// subjects, so no pair reaching here is ever ancestor-related and the
    /// rejecting branch is unreachable from the public entry point. Tests assert
    /// it directly instead, so it is covered rather than merely looking covered.
    static func isCrossBranch(_ first: [SemanticNode], _ second: [SemanticNode]) -> Bool {
        var shared = 0
        while shared < first.count, shared < second.count,
            first[shared].identity == second[shared].identity,
            first[shared].structuralPath == second[shared].structuralPath
        {
            shared += 1
        }
        // One is an ancestor of the other: the whole shorter path is the prefix.
        guard shared < first.count, shared < second.count else { return false }
        // Direct siblings: identical parents, differing only in the final node.
        if shared == first.count - 1 && shared == second.count - 1 { return false }
        return true
    }

    /// True when anything on the path declares a paint order — a `zIndex` on any
    /// node, or a `zstack` container anywhere above it.
    private static func declaresLayering(_ path: [SemanticNode]) -> Bool {
        path.contains { $0.zIndex != nil || $0.role.identifier.lowercased() == "zstack" }
    }
}
