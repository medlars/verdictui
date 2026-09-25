import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// CTS-71083452: a caller must be able to discover which probes accept an act
/// BEFORE calling `act`, rather than learning it from a refusal.
///
/// ### Why role is not the answer
///
/// `role` is a claim about what a node IS; actionability is a claim about what
/// the HARNESS can drive. A probe can carry `.toggle` with no binding — that is
/// exactly the case an exploring agent hits — so a consumer reading role alone
/// guesses, and guesses wrong on 8 of the 9 shipped demo scenarios.
///
/// ### The shape of these tests
///
/// Every assertion here is paired with a NEGATIVE control, because "reports
/// which probes are actionable" is otherwise satisfied by a function that
/// reports every probe (or every interactive-looking one). The control is a
/// probe with an interactive ROLE and no binding: it must be absent. Without
/// that half these tests pass against `return allProbeIDs` (`no.md` #17).
final class ActionDiscoveryTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// Render a shipped scenario by name and report its actionable probes.
    ///
    /// Goes through `DemoScenarios.all` rather than constructing each type, so
    /// this asks about the CATALOG a consumer sees rather than about types the
    /// test happens to know.
    @MainActor
    private static func actionable(for name: String) async throws -> [String: [String]] {
        let entry = try XCTUnwrap(
            DemoScenarios.all.first { $0.name == name },
            "no shipped scenario named '\(name)'"
        )
        let host = entry.makeHost()
        // Render first: bindings register during view evaluation, so asking a
        // host that has never rendered reports an empty set.
        _ = try await host.currentTree()
        return host.actionableProbes
    }

    @MainActor
    func testRemovedActionCannotBeDiscoveredOrInvokedAndCanReappear() async throws {
        let witness = RemovalWitness()
        let host = OracleHost(scenario: DisappearingActionScenario(witness: witness),
                              viewport: Size(width: 260, height: 180))
        _ = try await host.currentTree()
        XCTAssertEqual(host.actionableProbes["remove-me"], ["tap"])
        try host.apply(.tap("remove-me"))
        _ = try await host.currentTree()
        XCTAssertEqual(witness.count, 1)
        try host.apply(.toggle("show-control"))
        let hidden = try await host.currentTree()
        XCTAssertNil(hidden.node(withID: "remove-me"))
        XCTAssertNil(host.actionableProbes["remove-me"])
        XCTAssertThrowsError(try host.apply(.tap("remove-me"))) { error in
            XCTAssertEqual(error as? ProbeActionError, .unknownProbe("remove-me"))
        }
        XCTAssertEqual(witness.count, 1)
        try host.apply(.toggle("show-control"))
        let restored = try await host.currentTree()
        XCTAssertNotNil(restored.node(withID: "remove-me"))
        XCTAssertEqual(host.actionableProbes["remove-me"], ["tap"])
        try host.apply(.tap("remove-me"))
        XCTAssertEqual(witness.count, 2)
    }

    @MainActor
    func testRemovingOnlyActionRevokesItWhileSemanticTreeIsIdentical() async throws {
        let model = SiteSwitchModel()
        let host = OracleHost(scenario: SiteSwitchScenario(model: model),
                              viewport: Size(width: 220, height: 100))
        let before = try await host.currentTree()
        let dormant = host.state.boolBinding("same-site")
        host.state.registerTap("same-site") { model.fallbackCount += 1 }
        XCTAssertEqual(host.actionableProbes["same-site"], ["tap"])
        try host.apply(.tap("same-site"))
        XCTAssertEqual(model.target.count, 1)
        model.armed = false
        let withoutAction = try await host.currentTree()
        XCTAssertEqual(before, withoutAction, "the action preference must change independently of semantic geometry")
        XCTAssertNil(host.actionableProbes["same-site"])
        XCTAssertThrowsError(try host.apply(.tap("same-site")))
        XCTAssertThrowsError(try host.apply(.toggle("same-site")))
        XCTAssertEqual(model.target.count, 1)
        XCTAssertEqual(model.fallbackCount, 0)
        XCTAssertFalse(dormant.wrappedValue)
        model.armed = true
        let restored = try await host.currentTree()
        XCTAssertEqual(restored, before)
        XCTAssertEqual(host.actionableProbes["same-site"], ["tap"])
        try host.apply(.tap("same-site"))
        XCTAssertEqual(model.target.count, 2)
    }

    @MainActor
    func testLongLivedHostReleasesReplacedControlsAcrossRepeatedRemoval() async throws {
        var model: SiteSwitchModel? = SiteSwitchModel()
        weak var retiredModel: SiteSwitchModel?
        retiredModel = model
        var host: OracleHost? = autoreleasepool {
            OracleHost(scenario: SiteSwitchScenario(model: model!), viewport: Size(width: 220, height: 100))
        }
        weak var retiredHost: OracleHost?
        retiredHost = host
        weak var retiredView: AnyObject?
        retiredView = Mirror(reflecting: host!).children.first { $0.label == "hostingView" }?.value as AnyObject?
        XCTAssertNotNil(retiredView, "the diagnostic weak witness must identify the actual hosting view")
        let retainedState = host!.state
        let initial = try await host!.currentTree()
        for _ in 0..<32 {
            weak var retiredTarget: SiteTarget?
            retiredTarget = model!.target
            try host!.apply(.tap("same-site"))
            XCTAssertEqual(model!.target.count, 1)
            model!.armed = false
            let removed = try await host!.currentTree()
            XCTAssertEqual(removed, initial)
            XCTAssertThrowsError(try host!.apply(.tap("same-site")))
            model!.target = SiteTarget()
            _ = try await host!.currentTree()
            XCTAssertNil(retiredTarget, "removed callbacks must release each former control owner")
            model!.armed = true
            let restored = try await host!.currentTree()
            XCTAssertEqual(restored, initial)
            XCTAssertEqual(host!.actionableProbes["same-site"], ["tap"])
        }
        autoreleasepool { host = nil; model = nil }
        print("site-churn retirement host=\(retiredHost != nil) view=\(retiredView != nil) model=\(retiredModel != nil) actions=\(retainedState.actionableProbes)")
        XCTAssertNil(retiredHost)
        XCTAssertNil(retiredModel)
        XCTAssertThrowsError(try ProbeAction.tap("same-site").apply(to: retainedState))
    }

    @MainActor
    func testRenderedSameIDUsesCurrentOwnerAndCurrentType() async throws {
        let model = SiteSwitchModel()
        let host = OracleHost(scenario: SiteSwitchScenario(model: model),
                              viewport: Size(width: 220, height: 100))
        let original = model.target
        let before = try await host.currentTree()
        let replacement = SiteTarget()
        model.target = replacement
        let afterReplacement = try await host.currentTree()
        XCTAssertEqual(before, afterReplacement)
        try host.apply(.tap("same-site"))
        XCTAssertEqual(original.count, 0)
        XCTAssertEqual(replacement.count, 1)
        model.textMode = true
        let afterTypeChange = try await host.currentTree()
        XCTAssertEqual(before, afterTypeChange)
        XCTAssertEqual(host.actionableProbes["same-site"], ["setText"])
        XCTAssertThrowsError(try host.apply(.tap("same-site")))
        try host.apply(.setText("same-site", "current owner"))
        XCTAssertEqual(replacement.text, "current owner")
        XCTAssertEqual(original.text, "seed")
        XCTAssertEqual(replacement.count, 1)
    }

    // MARK: - The capability, at its source

    /// `ScenarioState` already holds every registration, so it is the only place
    /// that can answer this without a second registry to drift.
    @MainActor
    func testStateReportsRegisteredProbesAndOmitsUnregisteredOnes() {
        let state = ScenarioState()
        _ = state.boolBinding("bound-toggle", default: false)
        _ = state.stringBinding("bound-field", default: "")
        _ = state.doubleBinding("bound-slider", default: 0)
        state.registerTap("bound-button") {}

        let actionable = state.actionableProbes

        XCTAssertEqual(
            Set(actionable.keys),
            ["bound-toggle", "bound-field", "bound-slider", "bound-button"],
            "every registered probe must be reported"
        )

        // The negative control. `never-registered` is not merely absent from the
        // fixture — it is the assertion that separates this from a function
        // returning everything it was ever asked about.
        XCTAssertNil(
            actionable["never-registered"],
            "a probe with no binding must NOT be reported actionable"
        )
    }

    /// Verbs, not merely a boolean: `setText` against a bool binding is a
    /// type mismatch the caller can avoid only if it knows which verb applies.
    @MainActor
    func testEachProbeReportsTheVerbsItAccepts() {
        let state = ScenarioState()
        _ = state.boolBinding("t", default: false)
        _ = state.stringBinding("f", default: "")
        _ = state.doubleBinding("s", default: 0)
        state.registerTap("b") {}

        let actionable = state.actionableProbes

        XCTAssertEqual(actionable["t"], ["tap", "toggle"], "a bool accepts tap and toggle")
        XCTAssertEqual(actionable["f"], ["setText"])
        XCTAssertEqual(actionable["s"], ["setSlider"])
        XCTAssertEqual(actionable["b"], ["tap"])
    }

    // MARK: - Through the harness, on the shipped catalog

    /// The consumer-facing question, asked of a real scenario.
    ///
    /// `advanced-toggle` is bound; `collapsed-summary` is a real probe in the
    /// same tree that is not. Both are rendered by the same scenario, so this
    /// cannot pass by reporting the whole probe set.
    @MainActor
    func testAShippedScenarioReportsOnlyItsBoundProbes() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = try await host.currentTree()

        let actionable = host.actionableProbes

        XCTAssertNotNil(
            actionable[ToggleLayoutScenario.toggleProbeID],
            "the scenario's bound toggle must be discoverable"
        )
        XCTAssertNil(
            actionable["collapsed-summary"],
            "an unbound probe in the SAME tree must not be reported — this is the "
                + "control that makes the assertion above mean something"
        )
    }

    /// The shipped catalog must demonstrate the verb on more than one scenario.
    ///
    /// Until now exactly ONE of nine demo scenarios bound an action, so an agent
    /// exploring the catalog was refused on almost every act it tried — the
    /// tool's most distinctive verb was the least discoverable thing in it.
    ///
    /// Asserted per scenario rather than as a count: a bare `>= 3` is satisfied
    /// by any three and would stay green if a binding moved off a scenario onto
    /// a duplicate somewhere else.
    @MainActor
    func testMoreThanOneShippedScenarioDemonstratesActing() async throws {
        // Verbs are spelled per scenario rather than assumed uniform: a bool
        // binding accepts BOTH `tap` and `toggle` (performTap falls through to a
        // toggle when no separate handler is registered), while a tap handler
        // accepts only `tap`. Asserting one shape for all three would have been
        // wrong about the toggle — and was, on the first run of this test.
        let expected: [(name: String, probe: String, verbs: [String])] = [
            (
                ToggleLayoutScenario.scenarioName, ToggleLayoutScenario.toggleProbeID,
                ["tap", "toggle"]
            ),
            (UndersizedTapTargetScenario.scenarioName, "dismiss-button", ["tap"]),
            (OffscreenButtonScenario.scenarioName, "apply-button", ["tap"]),
        ]

        for case let (name, probe, verbs) in expected {
            let actionable = try await Self.actionable(for: name)
            XCTAssertEqual(
                actionable[probe],
                verbs,
                "\(name) must demonstrate acting on '\(probe)'"
            )
        }
    }

    /// The bindings above must not have changed what those scenarios PROVE.
    ///
    /// Each is a planted-defect fixture whose finding is the reason it ships. A
    /// tap handler is not supposed to move geometry — but "not supposed to" is
    /// an assumption, and this is the control that makes it a measurement.
    @MainActor
    func testBindingAnActionDidNotDisturbThePlantedDefects() async throws {
        let host = OracleHost(
            scenario: UndersizedTapTargetScenario(),
            viewport: UndersizedTapTargetScenario.recommendedViewport
        )
        let tree = try await host.currentTree()
        let button = try XCTUnwrap(tree.node(withID: "dismiss-button"))

        XCTAssertEqual(
            button.frame.width,
            UndersizedTapTargetScenario.buttonSize.width,
            "the planted undersized hit area must survive the action binding"
        )
        XCTAssertEqual(button.frame.height, UndersizedTapTargetScenario.buttonSize.height)
    }

    /// Discovery must agree with what `act` actually does.
    ///
    /// Two independent surfaces answering one question is how they drift, so
    /// this pins them together: every probe reported actionable must accept the
    /// verb it reports, and the unreported one must refuse.
    @MainActor
    func testDiscoveryAgreesWithTheRefusal() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = try await host.currentTree()
        let actionable = host.actionableProbes

        let bound = ToggleLayoutScenario.toggleProbeID
        XCTAssertTrue(actionable[bound]?.contains("toggle") == true)
        XCTAssertNoThrow(
            try host.apply(.toggle(bound)),
            "a probe reported as accepting `toggle` must accept it"
        )

        XCTAssertNil(actionable["collapsed-summary"])
        XCTAssertThrowsError(
            try host.apply(.tap("collapsed-summary")),
            "a probe NOT reported actionable must still refuse — discovery may not "
                + "quietly become permission"
        ) { error in
            XCTAssertEqual(
                error as? ProbeActionError,
                .unknownProbe("collapsed-summary")
            )
        }
    }
}

@MainActor
private final class RemovalWitness {
    var count = 0
}

private struct DisappearingActionScenario: VerdictScenario {
    let name = "disappearing-action"
    let witness: RemovalWitness

    @MainActor
    func body(state: ScenarioState) -> some View {
        let shown = state.boolBinding("show-control", default: true)
        return VStack {
            Toggle("Show", isOn: shown)
                .verdictProbe("show-control", role: .toggle)
            if shown.wrappedValue {
                Button("Action") { witness.count += 1 }
                    .verdictProbe("remove-me", role: .button, action: .tap { witness.count += 1 })
            }
        }
    }
}

@MainActor
private final class SiteTarget {
    var count = 0
    var text = "seed"
}

@MainActor
private final class SiteSwitchModel: ObservableObject {
    @Published var armed = true
    @Published var target = SiteTarget()
    @Published var textMode = false
    var fallbackCount = 0
}

private struct SiteSwitchScenario: VerdictScenario {
    let name = "site-switch"
    let model: SiteSwitchModel
    func body(state: ScenarioState) -> some View { SiteSwitchView(model: model) }
}

private struct SiteSwitchView: View {
    @ObservedObject var model: SiteSwitchModel
    var body: some View {
        let target = model.target
        let action: ProbeSiteAction = model.textMode
            ? .text(Binding(get: { target.text }, set: { target.text = $0 }))
            : .tap { target.count += 1 }
        if model.armed {
            Text("Identical semantic content").frame(width: 200, height: 40)
                .verdictProbe("same-site", role: .button, text: "Identical semantic content", action: action)
        } else {
            Text("Identical semantic content").frame(width: 200, height: 40)
                .verdictProbe("same-site", role: .button, text: "Identical semantic content")
        }
    }
}
