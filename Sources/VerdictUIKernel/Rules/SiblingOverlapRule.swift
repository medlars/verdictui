// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Two siblings must not cover each other unless the layout said so.
///
/// Fires when two visible, non-empty sibling frames intersect. Deliberate
/// layering is recognised two ways, so a `ZStack` badge over an avatar is not a
/// defect:
/// - either sibling declares a ``SemanticNode/zIndex`` (an explicit paint order
///   is a statement of intent), or
/// - the parent's role identifier is `zstack` (probes may label a layering
///   container that way).
///
/// Suppress per node with `attributes["verdict.suppress"] = .string("sibling-overlap")`.
public struct SiblingOverlapRule: LintRule {
    public static let id = "sibling-overlap"

    /// Overlap below this is float noise from layout arithmetic, not a defect.
    ///
    /// Deliberately spelled the same as ``ContentOverlapRule/tolerance``, and
    /// equal to ``LintContext/truncationTolerance``'s default: the three judge
    /// the same class of float artifact, so a hairline that one ignores and
    /// another reports as an ERROR is the rules disagreeing about identical
    /// geometry. A false positive here is not cosmetic — it teaches an agent to
    /// discount overlap findings, which is worse than the rule not existing.
    ///
    /// A static rather than a ``LintContext`` knob, because making it tunable
    /// changes a public type's shape for a value no caller has asked to tune.
    /// If a third rule ever needs it, promote all three to one
    /// `context.overlapTolerance` in a single commit rather than growing a
    /// fourth spelling here.
    public static let tolerance = 0.5

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var findings: [Finding] = []
        for parent in root.flattened() where !Self.isLayeringContainer(parent) {
            let children = parent.children
            for first in children.indices {
                for second in children.indices where second > first {
                    let lower = children[first]
                    let upper = children[second]
                    guard Self.isEligible(lower), Self.isEligible(upper) else { continue }
                    guard lower.zIndex == nil, upper.zIndex == nil else { continue }
                    guard let overlap = lower.frame.intersection(upper.frame) else { continue }
                    // A shared edge or a hairline of float noise is not a collision.
                    guard overlap.width > Self.tolerance, overlap.height > Self.tolerance else {
                        continue
                    }
                    let finding = context.makeFinding(
                        rule: Self.id,
                        node: upper,
                        message: "'\(upper.evidenceLabel)' overlaps sibling "
                            + "'\(lower.evidenceLabel)' by "
                            + "\(overlap.width.pointsDescription) x "
                            + "\(overlap.height.pointsDescription) pt",
                        suggestion: "give the siblings disjoint frames, or declare the "
                            + "layering with .zIndex() so the overlap reads as intentional",
                        defaultSeverity: .error
                    )
                    if let finding { findings.append(finding) }
                }
            }
        }
        return findings
    }

    private static func isEligible(_ node: SemanticNode) -> Bool {
        node.isVisible && !node.frame.isEmpty
    }

    private static func isLayeringContainer(_ node: SemanticNode) -> Bool {
        node.role.identifier.lowercased() == "zstack"
    }
}
