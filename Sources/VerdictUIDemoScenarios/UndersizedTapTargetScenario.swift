// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: an interactive control smaller than the macOS pointer
/// minimum in both dimensions.
/// **Rule that must catch it**: `tap-target`, on probe `dismiss-button`.
///
/// 6 x 6 pt is below the 12 x 12 pt floor
/// (``LintContext/macOSMinimumTapTarget``) by 6 pt on each axis, so the finding
/// does not rest on a boundary: a scenario planted at 11 pt would pass or fail
/// on how a font rounds. It is also comfortably above zero, which keeps
/// `ZeroSizeRule` — the rule that owns the collapsed-frame defect — silent, so
/// one planted defect still produces one finding.
///
/// **This was 18 x 18 pt until 2026-08-14**, when the macOS floor was recalibrated
/// from 28 pt to 12 pt because no standard macOS control reaches 28 pt (see
/// ``LintContext/macOSMinimumTapTarget`` for the measurements). 18 pt is a
/// perfectly ordinary control height — a native `Toggle` is exactly that — so it
/// stopped being a planted DEFECT the moment the threshold became correct, and
/// the scenario had to shrink with it. A demo whose "bug" is a legal size is not
/// a demo of anything.
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
    public static let buttonSize = Size(width: 6, height: 6)

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(spacing: 8) {
            Text("Notifications")
                .verdictProbe("notifications-title", role: .text, text: "Notifications")

            Button {
                // Deliberately inert: the planted defect is the hit AREA, and a
                // handler that changed the layout would move the measurement
                // this scenario exists to make. The binding is here so the
                // catalog demonstrates `actions`/`act` on more than one
                // scenario — an agent exploring it was previously refused
                // everywhere but demo-toggle-layout.
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
            .verdictProbe("dismiss-button", role: .button, action: .tap {})
        }
    }
}
