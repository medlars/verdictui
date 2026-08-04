// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// An interactive control must be big enough to hit.
///
/// Fires when a visible interactive node (see ``Role/isInteractive``) is smaller
/// than ``LintContext/minimumTapTarget`` in either dimension. The default
/// threshold is the permissive macOS pointer minimum (28x28 pt), so a firing rule
/// means the control is genuinely below the platform's documented floor; render a
/// scenario at touch metrics with ``LintContext/touch(viewport:scenario:)`` to
/// police 44x44 pt instead.
///
/// Empty frames are left to ``ZeroSizeRule`` so one defect produces one finding.
public struct TapTargetRule: LintRule {
    public static let id = "tap-target"

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        let minimum = context.minimumTapTarget
        return root.flattened().compactMap { node in
            guard node.role.isInteractive, node.isVisible, !node.frame.isEmpty else { return nil }
            guard node.frame.width < minimum.width || node.frame.height < minimum.height else {
                return nil
            }
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' is "
                    + "\(node.frame.width.pointsDescription) x "
                    + "\(node.frame.height.pointsDescription) pt, below the "
                    + "\(minimum.width.pointsDescription) x "
                    + "\(minimum.height.pointsDescription) pt minimum hit size",
                suggestion: "grow the control or add .frame(minWidth: "
                    + "\(minimum.width.pointsDescription), minHeight: "
                    + "\(minimum.height.pointsDescription))",
                defaultSeverity: .error
            )
        }
    }
}
