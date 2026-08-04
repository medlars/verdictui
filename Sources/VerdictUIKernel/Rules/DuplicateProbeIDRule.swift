// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A probe id must appear at most once per tree.
///
/// This is an infrastructure rule, not a layout one: duplicate ids break the two
/// mechanisms the whole product rests on. ``TreeDiff`` degrades that sibling group
/// to positional matching (so a delta stops describing identity), and act-targeting
/// (`tap("save-button")`, Wave 3) cannot say which element it meant. It therefore
/// evaluates first in ``RuleEngine/standardRules`` — other findings about the same
/// tree are less trustworthy while an id collision stands.
///
/// One finding per colliding id, attached to the first occurrence (which is also
/// the node whose `verdict.suppress` attribute governs it), ids reported in sorted
/// order for a stable wire format. Unprobed nodes (empty id) are not compared;
/// their identity comes from ``SemanticNode/structuralPath``.
public struct DuplicateProbeIDRule: LintRule {
    public static let id = "duplicate-probe-id"

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var firstOccurrence: [String: SemanticNode] = [:]
        var counts: [String: Int] = [:]
        for node in root.flattened() where !node.id.isEmpty {
            counts[node.id, default: 0] += 1
            if firstOccurrence[node.id] == nil { firstOccurrence[node.id] = node }
        }

        return counts.filter { $0.value > 1 }.keys.sorted().compactMap { duplicateID in
            guard let node = firstOccurrence[duplicateID], let count = counts[duplicateID] else {
                return nil
            }
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "probe id '\(duplicateID)' appears \(count) times — tree diffing falls "
                    + "back to positional matching and act-targeting becomes ambiguous",
                suggestion: "give each .verdictProbe a unique id, e.g. by suffixing the "
                    + "collection index",
                defaultSeverity: .error
            )
        }
    }
}
