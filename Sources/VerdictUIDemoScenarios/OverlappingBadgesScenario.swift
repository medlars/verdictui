// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: two sibling badges whose frames intersect, with no
/// layering declared anywhere.
/// **Rule that must catch it**: `sibling-overlap`, on probe `badge-sale`
/// (the rule attaches the finding to the later sibling).
///
/// The overlap is produced by an `HStack` with negative spacing rather than by
/// `.offset` or a `ZStack`, and the choice matters. Negative spacing is a real
/// layout outcome — the stack *places* the second badge 20 pt back over the
/// first — so the frames the probes report are the frames the layout engine
/// resolved, not a render-time transform laid over untouched geometry. It is
/// also the shape the accident takes in real code: a spacing constant computed
/// from a padding value that went negative.
///
/// Nothing here declares layering, deliberately. ``SiblingOverlapRule`` forgives
/// an overlap when either sibling carries a `zIndex` or when the parent's role
/// identifier is `zstack`, so the parent row is probed as a plain
/// ``Role/container`` and neither badge carries a paint order. See
/// ``CleanSettingsScenario`` for the same geometry with the layering declared,
/// which must stay silent.
///
/// The badges are probed as ``Role/text`` with their strings, and their sizes
/// are fixed *inside* the probe, so each badge's intrinsic width equals its
/// resolved width and `truncation` has nothing to say. One defect, one finding.
public struct OverlappingBadgesScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable, and not to be renamed.
    public static let scenarioName = "demo-overlapping-badges"

    /// The viewport this scenario's documented findings were recorded at.
    public static let recommendedViewport = Size(width: 240, height: 96)

    /// Badge size in points, applied inside each probe so the reported frame is
    /// exactly this and the intrinsic width cannot differ from it.
    public static let badgeSize = Size(width: 60, height: 24)

    /// Stack spacing. Negative by exactly the width of the intended overlap.
    public static let rowSpacing: Double = -20

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Offers")
                .verdictProbe("offers-title", role: .text, text: "Offers")

            HStack(spacing: Self.rowSpacing) {
                badge("NEW", tint: .blue)
                    .verdictProbe("badge-new", role: .text, text: "NEW")
                badge("SALE", tint: .orange)
                    .verdictProbe("badge-sale", role: .text, text: "SALE")
            }
            .verdictProbe("badge-row", role: .container)
        }
    }

    /// One fixed-size badge. The frame is inside the probe on purpose: see the
    /// type's documentation on why that keeps `truncation` out of this scenario.
    private func badge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: Self.badgeSize.width, height: Self.badgeSize.height)
            .background(Capsule().fill(tint))
    }
}
