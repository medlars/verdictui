// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Text must not lose characters to its frame.
///
/// Needs ``SemanticNode/textMetrics``, which Wave 2's layout probe attaches to
/// text-rendering nodes by measuring the same text twice — once unconstrained
/// (`intrinsicWidth`, `idealLineCount`), once at the real proposal
/// (`renderedLineCount`). Nodes without metrics are skipped rather than guessed
/// at; a rule that speculates is a rule people stop believing.
///
/// Two distinct defects:
/// 1. **Vertical truncation** — fewer lines rendered than wanted.
/// 2. **Single-line clipping** — a one-line text given less width than it needs.
///
/// Multi-line text narrower than its intrinsic width is *wrapping*, not
/// truncation, and is deliberately not reported: that case is the single largest
/// source of false positives in layout linting.
public struct TruncationRule: LintRule {
    public static let id = "truncation"

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        root.flattened().compactMap { node in
            guard node.isVisible, let metrics = node.textMetrics else { return nil }

            if metrics.isLineTruncated {
                return context.makeFinding(
                    rule: Self.id,
                    node: node,
                    message: "'\(node.evidenceLabel)' rendered \(metrics.renderedLineCount) of "
                        + "\(metrics.idealLineCount) lines",
                    suggestion: "allow \(metrics.idealLineCount) lines "
                        + "(.lineLimit(\(metrics.idealLineCount))) or increase the frame height",
                    defaultSeverity: .error
                )
            }

            let available = node.frame.width + context.truncationTolerance
            guard metrics.idealLineCount <= 1, available < metrics.intrinsicWidth else { return nil }
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' needs "
                    + "\(metrics.intrinsicWidth.pointsDescription) pt of width on one line but "
                    + "was given \(node.frame.width.pointsDescription) pt",
                suggestion: "increase frame width to >= intrinsicWidth "
                    + "\(metrics.intrinsicWidth.pointsDescription) pt, or allow wrapping",
                defaultSeverity: .error
            )
        }
    }
}
