// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: none, in either state. This is the act-and-observe
/// fixture, and its Wave 2 job is to be structurally interesting and
/// deterministic rather than defective.
/// **Rules that must stay silent** in the default (collapsed) state: all of
/// ``RuleEngine/standardRules``.
///
/// ### Two layouts behind one Bool, and why the state is an initializer
/// argument
///
/// Wave 2 has no action injection: nothing can flip a toggle between two
/// verdicts yet, so a scenario whose second layout could only be reached by
/// pressing something would have a second layout nobody could render or verify.
/// Constructing the state instead — `ToggleLayoutScenario(isExpanded: true)` —
/// makes both branches renderable *today*, which is what lets Wave 3 assert the
/// thing it actually cares about: that driving the toggle through
/// `ProbeAction.tap("advanced-toggle")` produces the tree this initializer
/// already produces. Without that, the Wave 3 test would be comparing a
/// post-action tree against nothing.
///
/// So the binding here is deliberately `.constant`, and deliberately temporary.
/// Wave 3 replaces it with one registered on the harness-owned ``ScenarioState``
/// and drives the same two layouts through an injected action; the probe ids
/// below are the targets it will name, which is why they are worth pinning now.
///
/// ### Why the name does not vary with the state
///
/// ``name`` is the baseline key, and a key that changed with the state would
/// file the before-tree and the after-tree of one interaction under two
/// different scenarios — so a Wave 3 delta would have nothing to diff against.
/// The state is a property of the render, not of the scenario's identity.
/// ``DemoScenarios/all`` therefore enumerates the collapsed state only; the
/// expanded one is reachable through this initializer, by name, from any test
/// that wants it.
///
/// Both layouts are built to produce no findings: the toggle is framed at
/// 260 x 28 pt (at the 28 pt macOS floor, which the rule reports only *below*),
/// the expanded button at 140 x 30 pt, and every text is left at its intrinsic
/// width so nothing is clipped. The stack's spacing keeps siblings disjoint.
public struct ToggleLayoutScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable across both states, and not to
    /// be renamed.
    public static let scenarioName = "demo-toggle-layout"

    /// The viewport both states are rendered at. Wide enough that no text is
    /// width-constrained in either branch.
    public static let recommendedViewport = Size(width: 360, height: 200)

    /// Toggle row size in points. The height is exactly
    /// ``LintContext/macOSMinimumTapTarget``'s 28 pt: `TapTargetRule` fires
    /// strictly below the minimum, so this is the smallest control that is
    /// still clean, and it fails the moment someone shaves a point off it.
    public static let toggleSize = Size(width: 260, height: 28)

    /// Size of the button that appears in the expanded state.
    public static let actionButtonSize = Size(width: 140, height: 30)

    /// Which layout to render. Wave 3 drives this through an injected action
    /// instead; see the type's documentation.
    public let isExpanded: Bool

    public var name: String { Self.scenarioName }

    /// - Parameter isExpanded: `false` renders the collapsed layout, which is
    ///   the state ``DemoScenarios/all`` enumerates and the state this
    ///   scenario's zero-findings guarantee is stated for.
    public init(isExpanded: Bool = false) {
        self.isExpanded = isExpanded
    }

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show advanced options", isOn: .constant(isExpanded))
                .toggleStyle(.switch)
                .frame(
                    width: Self.toggleSize.width,
                    height: Self.toggleSize.height,
                    alignment: .leading
                )
                .verdictProbe("advanced-toggle", role: .toggle)

            if isExpanded {
                Text("Cache size: 512 MB")
                    .verdictProbe("advanced-detail", role: .text, text: "Cache size: 512 MB")

                Button("Clear cache") {}
                    .buttonStyle(.plain)
                    .frame(
                        width: Self.actionButtonSize.width,
                        height: Self.actionButtonSize.height
                    )
                    .verdictProbe("clear-cache-button", role: .button)
            } else {
                Text("Advanced options are hidden")
                    .verdictProbe(
                        "collapsed-summary",
                        role: .text,
                        text: "Advanced options are hidden"
                    )
            }
        }
    }
}
