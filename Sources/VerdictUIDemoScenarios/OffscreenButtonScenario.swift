// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: a visible, hit-testable button parked entirely outside
/// the viewport.
/// **Rule that must catch it**: `offscreen`, on probe `apply-button`.
///
/// ### Why this scenario insists on an explicit viewport
///
/// "Outside the viewport" is a claim about a rectangle the scenario does not
/// own. ``OracleHost`` sizes itself from `fittingSize` when no viewport is
/// given, and `fittingSize` measures the content — including the offset button
/// — so the host would grow to swallow the very button this scenario plants
/// outside it, and `OffscreenRule` would correctly report nothing. The scenario
/// therefore publishes ``recommendedViewport`` and pins its own content to that
/// size with a transparent sizer, so the host size, the content bounds and the
/// rectangle the finding is measured against are all the same 320 x 200 pt.
/// ``DemoScenarios/all`` renders every entry at its recommended viewport for
/// exactly this reason.
///
/// ### Why `.offset` and not a layout overflow
///
/// `.offset` moves the rendered view — and the probe's reporter, which rides
/// inside it — without changing the space its parent allocated, so the button
/// reports a frame far to the right of the viewport while the surrounding
/// layout stays exactly as it would be if the bug were fixed. An overflowing
/// stack, the obvious alternative, would compress its flexible children and
/// change every other frame in the tree; the defect would then be entangled
/// with the layout instead of planted in it.
///
/// The offset is horizontal only, and larger than the viewport width plus the
/// button, so the frame clears the right edge with room to spare —
/// ``OffscreenRule`` reports only frames that lie *entirely* outside, and a
/// scenario that grazes the boundary would be a test of the epsilon rather than
/// of the rule.
public struct OffscreenButtonScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable, and not to be renamed.
    public static let scenarioName = "demo-offscreen-button"

    /// The viewport the planted defect is defined against. Rendering this
    /// scenario at any other size changes what "offscreen" means; rendering it
    /// with no viewport at all lets `fittingSize` absorb the defect.
    public static let recommendedViewport = Size(width: 320, height: 200)

    /// Button size in points — comfortably above the 28 x 28 pt macOS tap
    /// minimum, so `tap-target` stays out of this scenario's evidence.
    public static let buttonSize = Size(width: 88, height: 32)

    /// Horizontal displacement in points. Past `recommendedViewport.width`, so
    /// the button's leading edge alone already clears the viewport.
    public static let buttonOffset: Double = 420

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        ZStack(alignment: .topLeading) {
            // Pins the content to the viewport so the tree's geometry and the
            // rectangle the rule measures against cannot drift apart.
            Color.clear
                .frame(
                    width: Self.recommendedViewport.width,
                    height: Self.recommendedViewport.height
                )

            Text("Filters")
                .verdictProbe("filters-title", role: .text, text: "Filters")

            Button("Apply") {}
                .buttonStyle(.plain)
                .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                // Inert by design: the planted defect is the button's POSITION,
                // so a handler that moved anything would erase the measurement.
                // The binding exists so the shipped catalog demonstrates
                // `actions`/`act` on more than one scenario.
                .verdictProbe("apply-button", role: .button, action: .tap {})
                .offset(x: Self.buttonOffset, y: 40)
        }
    }
}
