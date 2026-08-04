// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A visible node must be somewhere the user can see it.
///
/// Fires when a visible, non-empty frame lies *entirely* outside
/// ``LintContext/viewport``. Partial overlap is not reported: content clipped at
/// a viewport edge is normal for scrollable and animating layouts, and the
/// dedicated `ClippedContentRule` (Wave 5) is the right place to judge it.
///
/// ``Role/spacer`` is exempt — a spacer pushed past the edge carries no content.
public struct OffscreenRule: LintRule {
    public static let id = "offscreen"

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        let viewport = context.viewport
        return root.flattened().compactMap { node in
            guard node.isVisible, !node.frame.isEmpty, node.role != .spacer else { return nil }
            guard !viewport.intersects(node.frame) else { return nil }
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' is visible but sits entirely outside the "
                    + "\(viewport.width.pointsDescription) x "
                    + "\(viewport.height.pointsDescription) pt viewport "
                    + "(frame origin \(node.frame.x.pointsDescription), "
                    + "\(node.frame.y.pointsDescription))",
                suggestion: "move it inside the viewport, or hide it while it is off-screen "
                    + "so the tree matches what renders",
                defaultSeverity: .error
            )
        }
    }
}
