// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Text must not wrap far past the width it was designed for.
///
/// The second-order blind spot behind the unprobed-view one: even with a probe
/// correctly attached, a label wrapping onto five lines in a header produced NO
/// finding. ``TruncationRule`` fires only when characters are LOST
/// (`renderedLineCount < idealLineCount`); SwiftUI wraps rather than clips, so
/// the two counts are equal and it is silent by construction. Measured on a real
/// screen: `intrinsicWidth 335.0` inside an 82 pt frame across five lines,
/// `findings: []`. A human sees that instantly.
///
/// This is the most common real SwiftUI layout defect — narrow windows, long
/// localized strings, accessibility text sizes — and none of those clip.
///
/// ## Why lines and not the width ratio
///
/// The obvious rule compares `intrinsicWidth` to the frame width and fires past
/// some multiple. Measurement says that cannot work. Hosting one 13 pt string at
/// seven widths gave ordinary two-line wraps at ratios 1.54, 1.88 and 2.00,
/// while `Internationalization` at 58 pt also sits at 2.00 — and the defect that
/// prompted the rule is at 3.88. A ratio threshold below 2.00 reports the normal
/// cases; one above it still cannot distinguish a wide-ratio two-line wrap from
/// a narrow-ratio five-line one. Line count separates them cleanly, so the rule
/// keys on ``LintContext/maximumWrappedLines`` and reports the ratio only as
/// evidence in the message.
///
/// Severity is `warning`, not `error`: wrapping is sometimes exactly what the
/// author wanted (a paragraph, a description block), and this rule cannot know
/// intent. It is a strong smell, not a proof.
///
/// Nodes with no ``SemanticNode/textMetrics`` are skipped rather than guessed
/// at, the same contract ``TruncationRule`` keeps.
public struct ExcessiveWrapRule: LintRule {
    public static let id = "excessive-wrap"

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        root.flattened().compactMap { node in
            guard node.isVisible, let metrics = node.textMetrics else { return nil }

            // Deliberately `idealLineCount`, the count the text WANTS, not
            // `renderedLineCount`. When a text both wraps excessively and is
            // then clipped, the rendered count is capped by the frame and would
            // hide the wrap behind the truncation — the two rules would fight
            // over one node and the quieter answer would win.
            guard metrics.idealLineCount > context.maximumWrappedLines else { return nil }

            // A zero-width frame is a different defect (`zero-size` owns it), and
            // dividing by it yields infinity in the evidence string.
            guard node.frame.width > context.truncationTolerance else { return nil }

            let ratio = metrics.intrinsicWidth / node.frame.width
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' wraps onto \(metrics.idealLineCount) lines — it "
                    + "needs \(metrics.intrinsicWidth.pointsDescription) pt but was given "
                    + "\(node.frame.width.pointsDescription) pt "
                    + "(\(ratio.ratioDescription)x)",
                suggestion: "widen the frame, shorten the text, or accept the wrap with "
                    + ".lineLimit(\(metrics.idealLineCount))",
                defaultSeverity: .warning
            )
        }
    }
}
