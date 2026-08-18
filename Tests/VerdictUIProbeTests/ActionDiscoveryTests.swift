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
