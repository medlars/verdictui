// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: an interactive control smaller than the macOS pointer
/// minimum in both dimensions.
/// **Rule that must catch it**: `tap-target`, on probe `dismiss-button`.
///
/// 18 x 18 pt is below the 28 x 28 pt floor
/// (``LintContext/macOSMinimumTapTarget``) by 10 pt on each axis, so the finding
/// does not rest on a boundary: a scenario planted at 27 pt would pass or fail
/// on how a font rounds. It is also comfortably above zero, which keeps
/// `ZeroSizeRule` — the rule that owns the collapsed-frame defect — silent, so
/// one planted defect still produces one finding.
///
/// The size is applied *inside* the probe, so the probe reports the control's
/// own box rather than a container that happens to sit around it. The button is
/// probed without a `text:` argument on purpose: ``Role/button`` is
/// text-bearing, and a string would let ``TruncationRule`` attach metrics to a
/// deliberately tiny frame and report a second, unplanted defect. What this
/// scenario is about is the hit area, not the glyphs.
///
/// Rendered at touch metrics (``LintContext/touch(viewport:scenario:)``, 44 x 44
/// pt) the same tree yields the same rule with a different threshold — useful
/// to Wave 5's platform sweep, and the reason the shortfall is stated in points
/// rather than as "half the minimum".
public struct UndersizedTapTargetScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable, and not to be renamed.
    public static let scenarioName = "demo-undersized-tap-target"

    /// The viewport this scenario's documented findings were recorded at.
    public static let recommendedViewport = Size(width: 200, height: 120)

    /// The planted hit area, in points. Below
    /// ``LintContext/macOSMinimumTapTarget`` on both axes.
    public static let buttonSize = Size(width: 18, height: 18)

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(spacing: 8) {
            Text("Notifications")
                .verdictProbe("notifications-title", role: .text, text: "Notifications")

            Button {
                // Wave 2 has no action injection; the button exists to be
                // measured, not pressed. Wave 3 gives it something to do.
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
            .verdictProbe("dismiss-button", role: .button)
        }
    }
}
