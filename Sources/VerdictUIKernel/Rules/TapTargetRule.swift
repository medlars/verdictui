// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// An interactive control must be big enough to hit.
///
/// Fires when a visible interactive node (see ``Role/isInteractive``) is smaller
/// than ``LintContext/minimumTapTarget`` in either dimension. The default
/// threshold is the macOS pointer minimum (12x12 pt), calibrated in Wave 10 to
/// the smallest control the platform itself will produce — a `.controlSize(.mini)`
/// switch measures 19x12 pt. A firing rule therefore means the control is
/// smaller than anything SwiftUI makes on request, i.e. it was shrunk by a
/// layout accident rather than by an API. Render a scenario at touch metrics
/// with ``LintContext/touch(viewport:scenario:)`` to police 44x44 pt instead.
///
/// The threshold was 28x28 pt until 2026-08-14 and fired on every standard
/// macOS control; see ``LintContext/macOSMinimumTapTarget`` for the measurements
/// that retired it.
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
