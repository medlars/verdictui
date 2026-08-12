import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// Scenarios that deliberately MISREPORT themselves — the honesty proof for the
/// cross-validation loop (Wave 8 Task 4 / SD1).
///
/// Every other scenario in this module is a UI with a real defect the *rules*
/// catch. These are different in kind: the UI is fine, and the **probe lies
/// about it**. That is the one failure the inner loop is structurally unable to
/// find, because a probe that misreports agrees with itself forever — the tree,
/// the rules, and the verdict are all computed from the same false premise, so
/// they concur perfectly and the verdict is confidently wrong.
///
/// Only a channel sharing none of that code can notice, which is what makes
/// these fixtures the reconciler's proof rather than merely its tests. If the
/// external witness fails to catch a planted lie, cross-validation is decorative
/// — so the catch rate is 100 % or the feature does not work.
///
/// ### Why these are a SEPARATE catalog
///
/// `DemoScenarios.all` is iterated by the sweep, by `list_scenarios`, by the
/// CLI and by the baseline suite. A scenario that lies on purpose would be
/// picked up by every one of those and reported as a product defect — the
/// catalog would stop describing "what VerdictUI verifies" and start including
/// its own test apparatus. They are also excluded from the demo report for the
/// same reason: a consumer diffing six baselines must not suddenly see nine.
///
/// ### The three lies are three MECHANISMS, not three flavours of one
///
/// A probe carries author-supplied `role:` and `text:` alongside a frame the
/// layout engine measures. Each lie corrupts a different one of those channels,
/// so a reconciler that only compares (say) geometry catches one fixture and
/// misses two — and a suite planting three geometry lies would report 100 %
/// while being blind to two thirds of the surface.
public enum LieScenarios {

    /// Every planted lie, with the finding each one must produce.
    ///
    /// The expected rule is declared **here in the fixture**, not read back off
    /// the reconciler, so a reconciler that stopped reporting a category fails
    /// this table rather than agreeing with itself about what it found.
    public static var all: [LieFixture] {
        [
            LieFixture(
                entry: DemoScenarioEntry(
                    viewport: MisreportedTextScenario.recommendedViewport,
                    probeIDs: ["receipt-title", "receipt-total"],
                    make: { MisreportedTextScenario() }
                ),
                probeID: "receipt-total",
                expectedRule: Reconcile.disagreementRule,
                lie: "the probe declares text the view never renders"
            ),
            LieFixture(
                entry: DemoScenarioEntry(
                    viewport: MisreportedRoleScenario.recommendedViewport,
                    probeIDs: ["checkout-title", "checkout-action"],
                    make: { MisreportedRoleScenario() }
                ),
                probeID: "checkout-action",
                // Reported as a VISIBILITY GAP, not a role disagreement, and the
                // reason is structural rather than a reconciler defect.
                // `structuralPath` embeds the role — `root/text[1]` against
                // `root/button[1]` — and it is the key the external channel is
                // matched on, because AX carries no probe ids. So a role lie
                // changes the node's own identity: the two channels never match
                // it up, and the honest answer is "the probe reports a node AX
                // cannot see", which is exactly what is emitted.
                //
                // Measured 2026-08-12 rather than assumed: the first draft of
                // this fixture expected `ax-disagreement` and the run said
                // otherwise. The lie IS caught, loudly and with the right node
                // cited; only the category differs from the guess.
                expectedRule: Reconcile.visibilityGapRule,
                lie: "the probe declares a role the platform does not publish"
            ),
            LieFixture(
                entry: DemoScenarioEntry(
                    viewport: InvisibleControlScenario.recommendedViewport,
                    probeIDs: ["confirm-title", "hidden-submit"],
                    make: { InvisibleControlScenario() }
                ),
                probeID: "hidden-submit",
                expectedRule: Reconcile.visibilityGapRule,
                lie: "the probe reports a control the accessibility tree cannot see"
            ),
        ]
    }

    /// The control: a scenario that plants NO lie.
    ///
    /// Without it, "every lie is caught" is satisfied by a reconciler that
    /// reports every node as a disagreement — a detector that fires on
    /// everything has a perfect catch rate and zero worth (`no.md` #17). The
    /// honest fixture must produce NO reconciliation finding at all.
    public static var honestControl: LieFixture {
        LieFixture(
            entry: DemoScenarioEntry(
                viewport: HonestScenario.recommendedViewport,
                probeIDs: ["honest-label"],
                make: { HonestScenario() }
            ),
            probeID: "honest-label",
            expectedRule: nil,
            lie: "nothing — this is the control that must produce no finding"
        )
    }

    /// Every fixture including the control — what the witness host resolves
    /// against, and what a full honesty run iterates.
    public static var allIncludingControl: [LieFixture] { all + [honestControl] }

    /// The fixture named `name`, or `nil`.
    public static func fixture(named name: String) -> LieFixture? {
        allIncludingControl.first { $0.name == name }
    }

    /// Resolve a scenario name across BOTH catalogs — the demo scenarios and
    /// the lie fixtures.
    ///
    /// The witness host needs to render either kind, and this is the ONE place
    /// that decides which catalog a name belongs to. A host that searched the
    /// two arrays itself would be a second implementation of the same rule, and
    /// the two would drift the first time a catalog gained an entry — which is
    /// exactly how the lie fixtures were unreachable from the witness in the
    /// first place.
    ///
    /// Demo scenarios are searched first so a lie fixture can never shadow a
    /// user-facing scenario, whatever it is named.
    public static func anyEntry(named name: String) -> DemoScenarioEntry? {
        DemoScenarios.entry(named: name) ?? fixture(named: name)?.entry
    }

    /// How many lies are planted. Pinned as a literal so adding a fixture
    /// without extending the tests fails loudly, rather than the coverage test
    /// quietly measuring whatever happens to be there.
    public static let count = 3
}

/// One planted lie and the finding it must produce.
///
/// Wraps a ``DemoScenarioEntry`` rather than re-implementing one. Both channels
/// must render the fixture the same way the demo catalog renders its scenarios
/// — the probed body through `witnessBody()`, the same host construction — and
/// a second entry type would be a second implementation of that rule, free to
/// drift in the one direction neither catalog's tests can observe.
public struct LieFixture {
    /// The catalog entry that renders this fixture in both channels.
    public let entry: DemoScenarioEntry
    /// The probe carrying the lie — the node a finding must cite.
    public let probeID: String
    /// Rule the reconciler must report, or `nil` for the honest control.
    public let expectedRule: String?
    /// What is being misrepresented, in one line, for the failure message.
    public let lie: String

    /// The scenario's name, as a verdict files it.
    public var name: String { entry.name }
    /// Viewport the lie is stated at.
    public var viewport: Size { entry.recommendedViewport }

    public init(entry: DemoScenarioEntry, probeID: String, expectedRule: String?, lie: String) {
        self.entry = entry
        self.probeID = probeID
        self.expectedRule = expectedRule
        self.lie = lie
    }

    /// A fresh host rendering this fixture at its stated viewport.
    @MainActor
    public func makeHost() -> OracleHost { entry.makeHost() }
}

// MARK: - Lie 1: the probe declares text the view never renders

/// A total that READS as one number and REPORTS as another.
///
/// The most valuable lie to catch and the least visible, because it is the one
/// with real-world consequences: a receipt showing $49.99 while every automated
/// check agrees it says $9.99 is a defect no screenshot diff and no rule can
/// find, since both channels downstream of the probe are consistent with each
/// other. Only a witness reading the platform's own text notices.
public struct MisreportedTextScenario: VerdictScenario, Sendable {
    public static let scenarioName = "lie-misreported-text"
    public static let recommendedViewport = Size(width: 260, height: 120)

    /// What the view actually renders.
    public static let renderedText = "$49.99"
    /// What the probe claims it renders. The gap is deliberate and large: a
    /// near-miss would test the comparison's tolerance rather than its
    /// existence, and tolerance has its own tests.
    public static let claimedText = "$9.99"

    public var name: String { Self.scenarioName }
    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Order total")
                .font(.headline)
                .verdictProbe("receipt-title", role: .text, text: "Order total")

            Text(Self.renderedText)
                .font(.system(size: 28, weight: .semibold))
                // THE LIE: `text:` is author-supplied and never checked against
                // what `Text` renders, so this passes every inner-loop gate.
                .verdictProbe("receipt-total", role: .text, text: Self.claimedText)
        }
        .padding(16)
    }
}

// MARK: - Lie 2: the probe declares a role the platform does not publish

/// A control that IS a button and is REPORTED as static text.
///
/// This lie is worse than a wrong label because it silences whole rule
/// families: `TapTargetRule` only measures interactive roles, so a button
/// misreported as text is exempt from the minimum-hit-size check by
/// construction. The rules do not fail — they are never asked, which is
/// indistinguishable from passing in every report downstream.
public struct MisreportedRoleScenario: VerdictScenario, Sendable {
    public static let scenarioName = "lie-misreported-role"
    public static let recommendedViewport = Size(width: 260, height: 120)

    /// Deliberately below `LintContext.macOSMinimumTapTarget` on the vertical
    /// axis, so the misreported role is not merely wrong — it is *load-bearing*
    /// for the verdict. Told the truth, this control fails `tap-target`.
    public static let buttonSize = Size(width: 80, height: 18)

    public var name: String { Self.scenarioName }
    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Checkout")
                .font(.headline)
                .verdictProbe("checkout-title", role: .text, text: "Checkout")

            Button("Pay now") {}
                .buttonStyle(.plain)
                .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                // THE LIE: a real `Button` reported as `.text`. AX publishes
                // AXButton regardless of what the probe claims, so the two
                // channels disagree about what this element *is*.
                .verdictProbe("checkout-action", role: .text, text: "Pay now")
        }
        .padding(16)
    }
}

// MARK: - Lie 3: the probe reports a control the accessibility tree cannot see

/// A submit control the probe reports and assistive technology cannot reach.
///
/// `.accessibilityHidden(true)` on an interactive control is the shape of a
/// real and common bug, which is why this fixture doubles as the accessibility
/// audit the plan names as a marketing point: the same machinery that proves
/// the probes honest also finds every control a screen-reader user cannot
/// operate. The probe sees it because the layout engine laid it out; AX does
/// not, because the author removed it from the tree.
public struct InvisibleControlScenario: VerdictScenario, Sendable {
    public static let scenarioName = "lie-invisible-control"
    public static let recommendedViewport = Size(width: 260, height: 140)

    /// Comfortably above the minimum tap target, so the visibility gap is the
    /// ONLY thing wrong here. A fixture that also failed `tap-target` could be
    /// "caught" by a reconciler that never ran at all.
    public static let buttonSize = Size(width: 120, height: 44)

    public var name: String { Self.scenarioName }
    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm")
                .font(.headline)
                .verdictProbe("confirm-title", role: .text, text: "Confirm")

            Button("Submit") {}
                .buttonStyle(.plain)
                .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                // THE LIE: probed as a reachable button, then removed from the
                // accessibility tree. The inner loop reports a healthy control;
                // a screen-reader user cannot find it at all.
                .accessibilityHidden(true)
                .verdictProbe("hidden-submit", role: .button, text: "Submit")
        }
        .padding(16)
    }
}

// MARK: - The control: a scenario that lies about nothing

/// The honest fixture. Every probe states exactly what its view renders.
///
/// This is the half that makes the other three mean something. A reconciler
/// that flagged every node would catch all three lies and score a perfect
/// 100 %, so the suite must also prove it stays silent when there is nothing to
/// report — otherwise the catch rate measures noise, not detection.
public struct HonestScenario: VerdictScenario, Sendable {
    public static let scenarioName = "lie-control-honest"
    public static let recommendedViewport = Size(width: 260, height: 120)

    /// Rendered AND claimed — one constant, so the fixture cannot drift into
    /// accidentally lying and quietly invert the control.
    public static let labelText = "All set"

    public var name: String { Self.scenarioName }
    public init() {}

    public func body(state: ScenarioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.labelText)
                .font(.headline)
                .verdictProbe("honest-label", role: .text, text: Self.labelText)
        }
        .padding(16)
    }
}
