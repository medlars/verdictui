// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: none, in either state. This is the act-and-observe
/// fixture, and its job is to be structurally interesting and deterministic
/// rather than defective.
/// **Rules that must stay silent** in the default (collapsed) state: all of
/// ``RuleEngine/standardRules``.
///
/// ### Two layouts behind one Bool
///
/// Wave 3 drives the toggle through ``ProbeAction/toggle(_:)`` /
/// ``ProbeAction/tap(_:)`` against the binding registered on
/// ``ScenarioState``. The initializer still accepts `isExpanded` so tests can
/// seed either layout without an action (and so the expanded tree remains the
/// oracle for "what tap should produce").
///
/// ### Why the name does not vary with the state
///
/// ``name`` is the baseline key, and a key that changed with the state would
/// file the before-tree and the after-tree of one interaction under two
/// different scenarios — so a Wave 3 delta would have nothing to diff against.
/// The state is a property of the render, not of the scenario's identity.
/// ``DemoScenarios/all`` therefore enumerates the collapsed state only; the
/// expanded one is reachable through this initializer or through an injected
/// action.
///
/// Both layouts are built to produce no findings: the toggle is framed at
/// 260 x 28 pt (at the 28 pt macOS floor, which the rule reports only *below*),
/// the expanded button at 140 x 30 pt, and every text is left at its intrinsic
/// width so nothing is clipped. The stack's spacing keeps siblings disjoint.
public struct ToggleLayoutScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable across both states, and not to
    /// be renamed.
    public static let scenarioName = "demo-toggle-layout"

    /// Probe id of the toggle Wave 3 actions target.
    public static let toggleProbeID = "advanced-toggle"

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

    /// Seed for the toggle binding on first ``ScenarioState/boolBinding(_:default:)``
    /// call. After that, actions own the value.
    public let isExpanded: Bool

    public var name: String { Self.scenarioName }

    /// - Parameter isExpanded: `false` renders the collapsed layout, which is
    ///   the state ``DemoScenarios/all`` enumerates and the state this
    ///   scenario's zero-findings guarantee is stated for.
    public init(isExpanded: Bool = false) {
        self.isExpanded = isExpanded
    }

    public func body(state: ScenarioState) -> some View {
        ToggleLayoutView(
            isOn: state.boolBinding(Self.toggleProbeID, default: isExpanded)
        )
    }
}

/// Nested so `@Binding` drives `if isOn` invalidation — reading
/// `binding.wrappedValue` in the scenario body's `@ViewBuilder` was not a
/// stable observation point under headless hosting.
private struct ToggleLayoutView: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show advanced options", isOn: $isOn)
                .toggleStyle(.switch)
                .frame(
                    width: ToggleLayoutScenario.toggleSize.width,
                    height: ToggleLayoutScenario.toggleSize.height,
                    alignment: .leading
                )
                .verdictProbe(
                    ToggleLayoutScenario.toggleProbeID,
                    role: .toggle,
                    action: .bool($isOn)
                )

            if isOn {
                Text("Cache size: 512 MB")
                    .verdictProbe("advanced-detail", role: .text, text: "Cache size: 512 MB")

                Button("Clear cache") {}
                    .buttonStyle(.plain)
                    .frame(
                        width: ToggleLayoutScenario.actionButtonSize.width,
                        height: ToggleLayoutScenario.actionButtonSize.height
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
