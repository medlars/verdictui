// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: a single-line label given less width than its glyphs need.
/// **Rule that must catch it**: `truncation`, on probe `storage-detail`.
///
/// The defect is planted the only way it can be planted honestly — with the
/// width constraint applied *outside* the probe. `.verdictProbe` reports the
/// frame the wrapped view resolved to and, through `ProbeLayout`, the width that
/// view asked for under an unconstrained proposal; a `.frame(width:)` applied
/// *inside* the probe would make both numbers 120 and the rule would be right to
/// stay silent. Outside it, the probe reports a clipped frame next to an
/// intrinsic width far wider than it, which is exactly the evidence
/// `TruncationRule` needs.
///
/// `.lineLimit(1)` is load-bearing for the same reason: without it the text
/// wraps, `idealLineCount` climbs above one, and the rule deliberately treats
/// that as wrapping rather than truncation — the single largest source of false
/// positives in layout linting, and not the defect this scenario plants.
///
/// The heading above the label is a control, not scenery: it is probed the same
/// way and left unconstrained, so a run that reported two truncation findings
/// would be reporting one real defect and one manufactured by the harness.
public struct TruncatingLabelScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable, and not to be renamed.
    public static let scenarioName = "demo-truncating-label"

    /// The viewport this scenario's documented findings were recorded at.
    ///
    /// Wide enough that the viewport is not itself the constraint: the label is
    /// clipped by its own 120 pt frame, so the finding does not quietly depend
    /// on the host size a caller happened to choose.
    public static let recommendedViewport = Size(width: 240, height: 96)

    /// Width the detail label is allowed, in points — less than
    /// ``detailText`` needs on one line.
    public static let detailWidth: Double = 120

    /// The heading, which fits at its intrinsic width and must produce nothing.
    public static let headingText = "Storage"

    /// The clipped string. Long enough that no plausible system font renders it
    /// inside ``detailWidth``.
    public static let detailText = "Quarterly revenue reconciliation summary"

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.headingText)
                .verdictProbe("storage-title", role: .text, text: Self.headingText)

            Text(Self.detailText)
                .lineLimit(1)
                .verdictProbe("storage-detail", role: .text, text: Self.detailText)
                .frame(width: Self.detailWidth, alignment: .leading)
        }
    }
}
