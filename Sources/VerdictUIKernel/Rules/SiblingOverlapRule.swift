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
