// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A node that claims to be visible must have somewhere to render.
///
/// Fires on a visible node with an empty frame — the classic "my view
/// disappeared" bug, where the element exists in the hierarchy but was proposed
/// zero space. Invisible nodes are skipped: hidden scaffolding is not a defect.
///
/// Exempt by role: ``Role/spacer`` (a zero-size spacer is a legitimate layout
/// outcome) and any role identifier prefixed `verdict.` (VerdictUI's own probe
/// scaffolding, which is deliberately sizeless).
///
/// Severity depends on what was lost: text and interactive roles are errors
/// (content or a control the user cannot see or reach), everything else is a
/// warning, since an empty container may simply have no content this time.
public struct ZeroSizeRule: LintRule {
    public static let id = "zero-size"

    /// Role-identifier prefix reserved for VerdictUI's own probe scaffolding.
    public static let probeRolePrefix = "verdict."

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        root.flattened().compactMap { node in
            guard node.isVisible, node.frame.isEmpty, !Self.isExempt(node.role) else { return nil }
            let severity: Finding.Severity =
                (node.role.isTextBearing || node.role.isInteractive) ? .error : .warning
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' is visible but its frame is "
                    + "\(node.frame.width.pointsDescription) x "
                    + "\(node.frame.height.pointsDescription) pt",
                suggestion: "give it a non-zero frame, hide it while it has no size, "
                    + "or report it as Role.spacer if it is layout-only",
                defaultSeverity: severity
            )
        }
    }

    private static func isExempt(_ role: Role) -> Bool {
        role == .spacer || role.identifier.hasPrefix(probeRolePrefix)
    }
}
