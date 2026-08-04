// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// **Planted defect**: none. This is the false-positive guard.
/// **Rules that must stay silent**: all of ``RuleEngine/standardRules`` under
/// ``LintContext/macOS(viewport:scenario:)``.
///
/// A verification engine is judged by what it *doesn't* say as much as by what
/// it does, and every one of the five other scenarios in this catalog only
/// proves a rule can fire. This one proves the rules can hold their tongue on a
/// layout that is merely ordinary — and its zero-findings assertion lives in
/// Wave 2's own tests rather than waiting for Task 6, because a false positive
/// discovered late is a rule nobody trusts by then.
///
/// ### Every rule's negative path, exercised on purpose
///
/// | Rule | What makes it hard to stay silent here |
/// |---|---|
/// | `sibling-overlap` | The card and its status pill **genuinely intersect** — 40 x 16 pt of shared area, the same geometry ``OverlappingBadgesScenario`` is failed for. The difference is that the layering is *declared*: the enclosing container is probed as `Role.custom("zstack")`, which the rule reads as intent. |
/// | `truncation` | Every text is left at its intrinsic width, so `intrinsicWidth` and the resolved frame agree to the point; the buttons are sized inside their probes, so a fixed frame is also the ideal one. |
/// | `tap-target` | Both buttons are 96 x 32 pt, above the 28 x 28 pt macOS floor on both axes. |
/// | `offscreen` | The whole stack is 240 x 156 pt inside a 360 x 260 pt viewport. |
/// | `zero-size` | Nothing is proposed zero space; the transparent sizer inside the layering container is unprobed, so it is not in the tree to be judged. |
/// | `duplicate-probe-id` | Six probes, six ids. |
///
/// ### The one thing the probe cannot see, and what this scenario does about it
///
/// SwiftUI's `.zIndex()` is applied below for real paint order, but Wave 2's
/// ``ProbeRecord`` carries no z-index field, so it never reaches
/// ``SemanticNode/zIndex`` and ``SiblingOverlapRule`` cannot read it. The
/// layering must therefore be declared the other way the rule accepts — the
/// parent's role identifier being `zstack` — and that is not a workaround being
/// papered over: it is the only channel that exists in this wave, and a clean
/// scenario that relied on the invisible one would be silently one probe change
/// away from failing. When a later wave teaches the probe to report z-index,
/// this scenario should keep passing for two reasons instead of one.
public struct CleanSettingsScenario: VerdictScenario, Sendable {
    /// Baseline key from Wave 5 onward — stable, and not to be renamed.
    public static let scenarioName = "demo-clean-settings"

    /// The viewport the zero-findings guarantee is stated at.
    public static let recommendedViewport = Size(width: 360, height: 260)

    /// Size of the layering container, in points. Strictly larger than both of
    /// its probed children so the assembled tree nests them under it — two
    /// probes with identical frames would stay siblings of *their* parent
    /// instead (``TreeAssembly/strictlyContains(_:_:)``), and the declared
    /// layering would then be attached to the wrong node.
    public static let cardLayerSize = Size(width: 240, height: 80)

    /// Size of the card surface, in points.
    public static let cardSize = Size(width: 220, height: 64)

    /// Size of the status pill that straddles the card's trailing edge.
    public static let pillSize = Size(width: 60, height: 24)

    /// Leading inset of the status pill, in points. Places it 40 pt over the
    /// card and 20 pt past it, so the two frames intersect without either one
    /// containing the other.
    public static let pillLeadingInset: Double = 180

    /// Top inset of the card surface, in points — the vertical half of the
    /// same intersection.
    public static let cardTopInset: Double = 8

    /// Size of each footer button, in points. Above
    /// ``LintContext/macOSMinimumTapTarget`` on both axes.
    public static let buttonSize = Size(width: 96, height: 32)

    public var name: String { Self.scenarioName }

    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.headline)
                .verdictProbe("settings-title", role: .text, text: "General")

            cardLayer

            HStack(spacing: 12) {
                Button("Cancel") {}
                    .buttonStyle(.plain)
                    .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                    .verdictProbe("cancel-button", role: .button, text: "Cancel")

                Button("Save") {}
                    .buttonStyle(.plain)
                    .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                    .verdictProbe("save-button", role: .button, text: "Save")
            }
            .verdictProbe("button-row", role: .container)
        }
    }

    /// The card and the pill that deliberately overlaps it, inside a container
    /// probed as a layering container.
    ///
    /// The insets are applied *outside* each probe so the probes report where
    /// the views ended up rather than the padded boxes around them, and the
    /// transparent sizer fixes the container's bounds so they do not shrink to
    /// the union of its children — which would make the container coincide with
    /// a child's frame and stop being its parent.
    ///
    /// `@MainActor` because ``SwiftUI/View/verdictProbe(_:role:text:attributes:)``
    /// is, and this helper is only ever evaluated from ``body(state:)``, which
    /// the protocol already isolates to the main actor.
    @MainActor
    private var cardLayer: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: Self.cardLayerSize.width, height: Self.cardLayerSize.height)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .verdictProbe("card-surface", role: .container)
                .padding(.top, Self.cardTopInset)
                .zIndex(0)

            Text("BETA")
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: Self.pillSize.width, height: Self.pillSize.height)
                .background(Capsule().fill(Color.accentColor))
                .verdictProbe("card-pill", role: .container)
                .padding(.leading, Self.pillLeadingInset)
                .zIndex(1)
        }
        .verdictProbe("card-layer", role: .custom("zstack"))
    }
}
