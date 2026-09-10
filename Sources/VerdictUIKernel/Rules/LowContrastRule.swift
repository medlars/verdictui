// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Text must be legible against what it is drawn on.
///
/// Fires when a visible node that renders text carries a sampled
/// `color.contrast` (see ``ColorSampler``) below ``minimumRatio``, the WCAG 2.x
/// AA floor for body text. The attribute is written only by a pixel-backed read
/// (`verdictui inspect --colors`, `judge --pid … --colors`), so a tree without
/// colour — every probe-channel tree — produces no finding at all: the rule
/// judges colour where colour was observed and is silent, not passing, where it
/// was not.
///
/// Severity is a WARNING because the colours are sampled from pixels rather
/// than read from a style: a node whose region is dominated by a sibling's
/// drawing can report the sibling's colours. The finding cites both colours so
/// a reader can check the sample against the screen.
public struct LowContrastRule: LintRule {
    public static let id = "low-contrast"

    /// WCAG 2.x success criterion 1.4.3 (AA), normal-size text.
    public static let minimumRatio = 4.5

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        root.flattened().compactMap { node in
            guard node.isVisible, let text = node.text, !text.isEmpty,
                let ratio = node.attributes[ColorSampler.contrastKey]?.numberValue,
                ratio < Self.minimumRatio
            else { return nil }
            let foreground = node.attributes[ColorSampler.foregroundKey]?.stringValue ?? "?"
            let background = node.attributes[ColorSampler.backgroundKey]?.stringValue ?? "?"
            return context.makeFinding(
                rule: Self.id,
                node: node,
                message: "'\(node.evidenceLabel)' text contrast is "
                    + String(format: "%.2f", ratio) + ":1 (\(foreground) on \(background)), "
                    + "below the 4.5:1 WCAG AA minimum",
                suggestion: "darken the text or lighten its background until the ratio "
                    + "reaches 4.5:1",
                defaultSeverity: .warning
            )
        }
    }
}
