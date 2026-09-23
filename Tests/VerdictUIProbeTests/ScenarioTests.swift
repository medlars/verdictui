import AppKit
import Combine
import Observation
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// What a scenario author is promised: write a name and a body, hand it to
/// ``OracleHost``, get a tree back — and never touch the sink, the coordinate
/// space, or the environment.
///
/// State belongs to one host across renders. Initial binding registration is
/// silent during body evaluation; later writes and actions notify observers.
final class ScenarioTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests. Without
    /// this the hosted hierarchies accumulate until the suite wedges at 0% CPU,
    /// each test still passing in isolation.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - Rendering

    @MainActor
    func testAScenarioBodyRendersThroughTheHost() async throws {
        let host = OracleHost(scenario: GreetingScenario(), viewport: Size(width: 200, height: 80))
        let tree = try await host.currentTree()

        // The author applied `.verdictProbe` and nothing else; the tree, the root
        // frame and the root-space coordinates all came from the host.
        let label = try XCTUnwrap(
            tree.node(withID: "greeting"),
            "the scenario's probed view never reached the tree"
        )
        XCTAssertEqual(label.role, .text)
        XCTAssertEqual(label.text, "Hello")
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertGreaterThan(label.frame.width, 0, "the probed label measured as zero width")
        XCTAssertNotNil(
            label.textMetrics,
            "a text probe below the host's root must reach the recorder the host installed"
        )
    }

    @MainActor
    func testTheScenarioNameRoundTripsThroughTheHost() async throws {
        let scenario = GreetingScenario()
        let host = OracleHost(scenario: scenario, viewport: Size(width: 200, height: 80))

        XCTAssertEqual(host.scenarioName, scenario.name)
        XCTAssertEqual(host.scenarioName, "greeting-screen")

        // The name is what a verdict is filed under, so it has to survive into the
        // context the kernel is handed — unmangled.
        let tree = try await host.currentTree()
        let context = LintContext.macOS(viewport: tree.frame, scenario: host.scenarioName)
        XCTAssertEqual(context.scenario, "greeting-screen")
    }

    // MARK: - ScenarioState

    /// Factories run inside body(state:); seeding a value must not invalidate
    /// the view whose first evaluation is already reading that value.
    @MainActor
    func testInitialBindingSeedsDoNotPublishChanges() {
        let state = ScenarioState()
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        XCTAssertTrue(state.boolBinding("bool", default: true).wrappedValue)
        XCTAssertEqual(notifications, 0, "initial bool seed published during rendering")
        XCTAssertEqual(state.stringBinding("text", default: "seed").wrappedValue, "seed")
        XCTAssertEqual(notifications, 0, "initial text seed published during rendering")
        XCTAssertEqual(state.doubleBinding("slider", default: 0.25).wrappedValue, 0.25)
        XCTAssertEqual(notifications, 0, "initial slider seed published during rendering")

        XCTAssertTrue(state.boolBinding("bool", default: false).wrappedValue)
        XCTAssertEqual(state.stringBinding("text", default: "replacement").wrappedValue, "seed")
        XCTAssertEqual(state.doubleBinding("slider", default: 0.75).wrappedValue, 0.25)
        XCTAssertEqual(notifications, 0, "reading existing bindings must not publish or reseed")
    }

    @MainActor
    func testInitialProbeRegistrationsDoNotPublishChanges() {
        let state = ScenarioState()
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        state.register(probeID: "bool", action: .bool(.constant(true)))
        XCTAssertEqual(notifications, 0, "initial bool registration published during rendering")
        state.register(probeID: "text", action: .text(.constant("seed")))
        XCTAssertEqual(notifications, 0, "initial text registration published during rendering")
        state.register(probeID: "slider", action: .slider(.constant(0.25)))
        XCTAssertEqual(notifications, 0, "initial slider registration published during rendering")

        state.register(probeID: "bool", action: .bool(.constant(false)))
        state.register(probeID: "text", action: .text(.constant("replacement")))
        state.register(probeID: "slider", action: .slider(.constant(0.75)))
        XCTAssertTrue(state.boolBinding("bool").wrappedValue)
        XCTAssertEqual(state.stringBinding("text").wrappedValue, "seed")
        XCTAssertEqual(state.doubleBinding("slider").wrappedValue, 0.25)
        XCTAssertEqual(notifications, 0, "re-registering must preserve the existing values")
    }

    @MainActor
    func testBindingWritesStillPublishChanges() {
        let state = ScenarioState()
        let bool = state.boolBinding("bool")
        let text = state.stringBinding("text")
        let slider = state.doubleBinding("slider")
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        bool.wrappedValue = true
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(bool.wrappedValue)
        text.wrappedValue = "changed"
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(text.wrappedValue, "changed")
        slider.wrappedValue = 0.75
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(slider.wrappedValue, 0.75)
    }

    @MainActor
    func testProbeActionMutationsStillPublishChanges() throws {
        let state = ScenarioState()
        state.register(probeID: "bool", action: .bool(.constant(false)))
        state.register(probeID: "text", action: .text(.constant("seed")))
        state.register(probeID: "slider", action: .slider(.constant(0.25)))
        var tapCount = 0
        state.registerTap("button") { tapCount += 1 }
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        try ProbeAction.toggle("bool").apply(to: state)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(state.boolBinding("bool").wrappedValue)
        try ProbeAction.setText("text", "changed").apply(to: state)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(state.stringBinding("text").wrappedValue, "changed")
        try ProbeAction.setSlider("slider", 0.75).apply(to: state)
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(state.doubleBinding("slider").wrappedValue, 0.75)
        try ProbeAction.tap("button").apply(to: state)
        XCTAssertEqual(notifications, 4)
        XCTAssertEqual(tapCount, 1)
    }

    /// The body is handed a state, the tree it produces varies on that state, and
    /// each host owns its own instance.
    ///
    /// "Varies on the state" is meant literally: the probed attribute below is
    /// computed from the `ScenarioState` the body received — `true` when it is the
    /// first instance the witness ever saw, `false` otherwise — so the two hosts
    /// produce two different trees for the same scenario value, and the only thing
    /// that differed between them was the state.
    ///
    /// One host owning one state is the guarantee Wave 3 needs: an action that
    /// mutates a binding registered at a probe site must reach the same object the
    /// next body evaluation reads. Two hosts sharing one would be worse than
    /// useless — a verdict for scenario A could be changed by acting on scenario B.
    @MainActor
    func testEachHostHandsItsBodyItsOwnScenarioState() async throws {
        let witness = StateWitness()
        let viewport = Size(width: 120, height: 60)

        let first = OracleHost(scenario: WitnessScenario(witness: witness), viewport: viewport)
        let firstTree = try await first.currentTree()
        XCTAssertEqual(
            try Self.attribute("is-first-state", of: "witness", in: firstTree),
            .bool(true),
            "the first host's body did not receive the first state the witness saw"
        )

        let second = OracleHost(scenario: WitnessScenario(witness: witness), viewport: viewport)
        let secondTree = try await second.currentTree()
        XCTAssertEqual(
            try Self.attribute("is-first-state", of: "witness", in: secondTree),
            .bool(false),
            "the second host reused the first host's ScenarioState"
        )

        XCTAssertEqual(witness.evaluations, 2, "each host must evaluate the body exactly once here")
        XCTAssertEqual(
            witness.distinctInstances,
            2,
            "two hosts must own two states, not share one"
        )
        XCTAssertNotEqual(
            firstTree,
            secondTree,
            "the trees are identical, so nothing in this test actually varied on the state"
        )
    }

    /// The other direction of the same guarantee, and the one Wave 3 actually
    /// leans on: *within* one host, every re-evaluation of the body is handed the
    /// **same** state object.
    ///
    /// ``testEachHostHandsItsBodyItsOwnScenarioState()`` proves two hosts do not
    /// share a state; that is the "not too shared" half. This is the "not too
    /// fresh" half, and without it the documented contract ("handed to every
    /// re-evaluation of the same scenario's body, never replaced between renders")
    /// would be enforced only by `ScenarioRoot.state` happening to be a `let` —
    /// a property nothing would fail if someone made it `@State` while chasing
    /// something else. An action that mutates a binding is worthless if the next
    /// body evaluation reads a different object.
    ///
    /// Re-evaluation is provoked, not waited for: `ScenarioRoot` has no mutable
    /// dependency of its own, so the scenario reads an `@Observable` counter and
    /// the test bumps it. That read happens inside `ScenarioRoot`'s body
    /// evaluation, so bumping it invalidates exactly the view whose re-evaluation
    /// is under test.
    @MainActor
    func testOneHostHandsEveryReEvaluationTheSameScenarioState() async throws {
        let witness = StateWitness()
        let trigger = RenderTrigger()
        let host = OracleHost(
            scenario: RerenderWitnessScenario(witness: witness, trigger: trigger),
            viewport: Size(width: 120, height: 60)
        )

        let firstTree = try await host.currentTree()
        XCTAssertEqual(
            try Self.attribute("generation", of: "witness", in: firstTree),
            .number(0)
        )
        let evaluationsAfterFirstRender = witness.evaluations

        trigger.generation += 1
        let secondTree = try await host.currentTree()

        XCTAssertEqual(
            try Self.attribute("generation", of: "witness", in: secondTree),
            .number(1),
            "the tree still reports generation 0, so the body was never re-evaluated and this "
                + "test cannot say anything about what a re-evaluation receives"
        )
        XCTAssertGreaterThan(
            witness.evaluations,
            evaluationsAfterFirstRender,
            "no further body evaluation happened after the invalidation"
        )
        XCTAssertEqual(
            witness.distinctInstances,
            1,
            "one host handed its body \(witness.distinctInstances) different ScenarioState "
                + "objects across \(witness.evaluations) evaluations; a Wave 3 binding "
                + "registered on the first would be orphaned by the second"
        )
    }

    /// The measurement pass that resolves `fittingSize` must not hand the real
    /// render its state, or Wave 3's bindings would be registered against an
    /// object that is about to be thrown away.
    @MainActor
    func testTheFittingSizeMeasurementPassUsesAThrowawayState() async throws {
        let witness = StateWitness()
        let host = OracleHost(scenario: WitnessScenario(witness: witness))
        _ = try await host.currentTree()

        XCTAssertEqual(
            witness.evaluations,
            2,
            "sizing by fittingSize evaluates the body once to measure and once to render"
        )
        XCTAssertEqual(
            witness.distinctInstances,
            2,
            "the measurement pass and the render pass shared a ScenarioState"
        )
    }

    // MARK: - Outside the harness

    /// A scenario is an ordinary view, so it renders with no harness at all — the
    /// `#Preview` story, and the reason ``ScenarioState`` has a public
    /// initializer.
    @MainActor
    func testAScenarioBodyRendersWithNoHarnessAtAll() {
        let view = NSHostingView(rootView: GreetingScenario().body(state: ScenarioState()))
        let fitting = view.fittingSize

        XCTAssertGreaterThan(fitting.width, 0, "the bare scenario body laid out to zero width")
        XCTAssertGreaterThan(fitting.height, 0, "the bare scenario body laid out to zero height")
    }

    // MARK: - Helpers

    private static func attribute(
        _ key: String,
        of id: String,
        in tree: SemanticNode
    ) throws -> AttributeValue {
        let node = try XCTUnwrap(tree.node(withID: id), "no node with id '\(id)' in the tree")
        return try XCTUnwrap(node.attributes[key], "node '\(id)' carries no '\(key)' attribute")
    }
}

// MARK: - Scenarios under test

private struct GreetingScenario: VerdictScenario {
    let name = "greeting-screen"

    func body(state: ScenarioState) -> some View {
        Text("Hello").verdictProbe("greeting", role: .text, text: "Hello")
    }
}

/// Reports, through the tree, which ``ScenarioState`` its body was handed.
private struct WitnessScenario: VerdictScenario {
    let name = "witness"

    let witness: StateWitness

    func body(state: ScenarioState) -> some View {
        Color.clear
            .frame(width: 40, height: 20)
            .verdictProbe(
                "witness",
                role: .container,
                attributes: ["is-first-state": .bool(witness.note(state))]
            )
    }
}

/// An invalidation handle: the scenario reads ``generation`` during its body
/// evaluation, so bumping it makes SwiftUI re-evaluate that body.
///
/// `@Observable` rather than a `@State` inside some child view, deliberately —
/// the read has to happen in the same body evaluation that calls
/// `scenario.body(state:)`, or the re-evaluation under test would be a child's
/// and not the scenario's.
@Observable
@MainActor
private final class RenderTrigger {
    var generation = 0
}

/// Reports both the state identity and the generation it was rendered at, so a
/// missing re-evaluation is distinguishable from a re-evaluation with a fresh
/// state.
private struct RerenderWitnessScenario: VerdictScenario {
    let name = "rerender-witness"

    let witness: StateWitness
    let trigger: RenderTrigger

    func body(state: ScenarioState) -> some View {
        Color.clear
            .frame(width: 40, height: 20)
            .verdictProbe(
                "witness",
                role: .container,
                attributes: [
                    "generation": .number(Double(trigger.generation)),
                    "is-first-state": .bool(witness.note(state)),
                ]
            )
    }
}

/// Records the states a scenario body was handed, and whether they were the same
/// object.
@MainActor
private final class StateWitness {
    private(set) var evaluations = 0
    private var seen: [ObjectIdentifier] = []
    private var firstSeen: ScenarioState?

    /// How many distinct `ScenarioState` objects have been handed to the body.
    var distinctInstances: Int { Set(seen).count }

    /// Record `state` and report whether it is the first one ever seen.
    func note(_ state: ScenarioState) -> Bool {
        evaluations += 1
        seen.append(ObjectIdentifier(state))
        guard let firstSeen else {
            self.firstSeen = state
            return true
        }
        return firstSeen === state
    }
}
