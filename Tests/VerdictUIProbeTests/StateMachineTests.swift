import SwiftUI
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIProbe

/// A walk drives a path through named states and verifies ARRIVAL at each one.
///
/// The load-bearing assertions are the ones proving a walk can FAIL: a machine
/// whose states carry no distinguishing expectations produces a walk that runs
/// every action, settles every time, and reports PASS while the UI never moved
/// — the false-green this whole product exists to prevent, arriving inside the
/// feature meant to catch it. So the construction guards are tested by their
/// rejection, and the arrival check is tested against a machine that names the
/// WRONG destination.
final class StateMachineTests: XCTestCase {

    // MARK: - Fixtures

    /// A disclosure panel: one toggle, and content that appears only when open.
    ///
    /// Deliberately a real conditional rather than an opacity change — the panel
    /// must be genuinely ABSENT from the tree when closed, so an expectation
    /// naming it fails with "no such element" rather than passing on a
    /// zero-sized ghost.
    ///
    /// The 44 pt control height is not decoration. The first draft probed a bare
    /// `Text` as `role: .button`, which measured 28x16 pt — and `TapTargetRule`
    /// correctly failed the transition step at the 28x28 pt macOS minimum. That
    /// was the engine catching a real defect in its own test fixture, and it is
    /// also the proof that a walk step carries its LINT findings alongside its
    /// arrival check rather than only the latter.
    private struct PanelScenario: VerdictScenario, Sendable {
        var name: String { "panel" }

        @MainActor func body(state: ScenarioState) -> some View {
            let isOpen = state.boolBinding("disclosure", default: false)
            return VStack(spacing: 8) {
                Text(isOpen.wrappedValue ? "Hide" : "Show")
                    .frame(width: 120, height: 44)
                    .verdictProbe(
                        "disclosure",
                        role: .button,
                        text: isOpen.wrappedValue ? "Hide" : "Show",
                        action: .bool(isOpen)
                    )
                if isOpen.wrappedValue {
                    Text("Panel body")
                        .verdictProbe("panel-body", role: .text, text: "Panel body")
                }
            }
            .frame(width: 240, height: 160)
        }
    }

    /// The two-state machine over ``PanelScenario``.
    ///
    /// Each state names an element the OTHER state does not have, which is what
    /// makes arrival falsifiable. States distinguished only by a shared element
    /// would be satisfied by either screen.
    private func panelMachine() throws -> ScenarioStateMachine {
        try ScenarioStateMachine(
            initial: "closed",
            states: [
                MachineState("closed", [Expectation("disclosure").visible.text("Show")]),
                MachineState("open", [Expectation("panel-body").visible.text("Panel body")]),
            ],
            transitions: [
                Transition(from: "closed", action: .toggle("disclosure"), to: "open"),
                Transition(from: "open", action: .toggle("disclosure"), to: "closed"),
            ]
        )
    }

    // MARK: - Construction guards

    /// A state with no expectations makes every arrival in it vacuously correct.
    ///
    /// This is the guard that matters most: without it a machine is a list of
    /// names, and a walk over names cannot fail for the reason walks exist.
    func testAStateWithNoExpectationsIsRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(
                initial: "a",
                states: [MachineState("a", [])],
                transitions: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.ValidationError,
                .stateHasNoExpectations("a")
            )
        }
    }

    func testADuplicateStateNameIsRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(
                initial: "a",
                states: [
                    MachineState("a", [Expectation("x").visible]),
                    MachineState("a", [Expectation("y").visible]),
                ],
                transitions: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.ValidationError,
                .duplicateState("a")
            )
        }
    }

    func testAnInitialStateOutsideTheSetIsRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(
                initial: "nowhere",
                states: [MachineState("a", [Expectation("x").visible])],
                transitions: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.ValidationError,
                .unknownInitialState("nowhere")
            )
        }
    }

    /// A transition to an undefined state would drive its action and then have
    /// nothing to check on arrival — a step that runs and reports without ever
    /// being able to fail.
    func testATransitionToAnUndefinedStateIsRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(
                initial: "a",
                states: [MachineState("a", [Expectation("x").visible])],
                transitions: [Transition(from: "a", action: .tap("x"), to: "ghost")]
            )
        ) { error in
            guard
                case .unknownTransitionState(_, let state)? = error
                    as? ScenarioStateMachine.ValidationError
            else {
                return XCTFail("expected unknownTransitionState, got \(error)")
            }
            XCTAssertEqual(state, "ghost")
        }
    }

    /// Two edges leaving one state on the same action make the walk's choice a
    /// function of declaration order rather than of the author's intent.
    func testTwoTransitionsLeavingOneStateOnTheSameActionAreRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(
                initial: "a",
                states: [
                    MachineState("a", [Expectation("x").visible]),
                    MachineState("b", [Expectation("y").visible]),
                    MachineState("c", [Expectation("z").visible]),
                ],
                transitions: [
                    Transition(from: "a", action: .tap("x"), to: "b"),
                    Transition(from: "a", action: .tap("x"), to: "c"),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.ValidationError,
                .ambiguousTransition(from: "a", action: "tap(x)")
            )
        }
    }

    /// The ambiguity key includes the action's VALUE, so two transitions that
    /// differ only in what they type are two distinct edges rather than a
    /// collision. Without this, a form machine could not model typing two
    /// different strings into one field.
    func testTransitionsDifferingOnlyInTypedTextAreNotAmbiguous() throws {
        let machine = try ScenarioStateMachine(
            initial: "empty",
            states: [
                MachineState("empty", [Expectation("field").visible]),
                MachineState("valid", [Expectation("field").visible]),
                MachineState("invalid", [Expectation("field").visible]),
            ],
            transitions: [
                Transition(from: "empty", action: .setText("field", "ok@example.com"), to: "valid"),
                Transition(from: "empty", action: .setText("field", "nope"), to: "invalid"),
            ]
        )
        XCTAssertEqual(machine.transitions.count, 2)
    }

    func testAnEmptyMachineIsRejected() {
        XCTAssertThrowsError(
            try ScenarioStateMachine(initial: "a", states: [], transitions: [])
        ) { error in
            XCTAssertEqual(error as? ScenarioStateMachine.ValidationError, .empty)
        }
    }

    // MARK: - Graph queries

    func testReachabilityFollowsTransitionsFromTheInitialState() throws {
        let machine = try ScenarioStateMachine(
            initial: "a",
            states: [
                MachineState("a", [Expectation("x").visible]),
                MachineState("b", [Expectation("y").visible]),
                MachineState("orphan", [Expectation("z").visible]),
            ],
            transitions: [Transition(from: "a", action: .tap("x"), to: "b")]
        )

        XCTAssertEqual(machine.reachableStates, ["a", "b"])
        XCTAssertEqual(machine.unreachableStates, ["orphan"])
    }

    /// A path the graph cannot walk must THROW rather than quietly become a
    /// shorter one — a truncated walk reports PASS for the steps it did take,
    /// and "3 of 5 states verified" reads exactly like "5 of 5" in a summary.
    func testAPathAskingForAnUndefinedMoveThrows() throws {
        let machine = try panelMachine()
        XCTAssertThrowsError(try machine.resolve(path: ["closed", "closed"])) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.PathError,
                .noTransition(from: "closed", to: "closed")
            )
        }
    }

    func testAPathNotStartingAtTheInitialStateThrows() throws {
        let machine = try panelMachine()
        XCTAssertThrowsError(try machine.resolve(path: ["open", "closed"])) { error in
            XCTAssertEqual(
                error as? ScenarioStateMachine.PathError,
                .doesNotStartAtInitial(given: "open", initial: "closed")
            )
        }
    }

    // MARK: - Walking

    @MainActor
    func testAWalkVerifiesArrivalAtEveryStateAlongThePath() async throws {
        let machine = try panelMachine()
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed", "open", "closed"])

        XCTAssertEqual(result.status, .pass, result.summary())
        // Three steps: the entry check plus one per transition. The entry check
        // is its own step so "the scenario did not start where you said" is
        // never blamed on the first action.
        XCTAssertEqual(result.steps.count, 3)
        XCTAssertEqual(result.steps.map(\.to), ["closed", "open", "closed"])
        XCTAssertNil(result.steps[0].action, "the entry check must not act")
        XCTAssertFalse(result.stoppedEarly)
        XCTAssertEqual(result.lastVerifiedState, "closed")
    }

    /// The load-bearing negative control: a machine that names the WRONG
    /// destination must FAIL. If this passes, arrival is not being checked and
    /// every other walk test is satisfied by a harness that only counts steps.
    @MainActor
    func testArrivingInADifferentStateThanTheGraphClaimsIsAFailure() async throws {
        // `closed --toggle--> closed` is a lie: toggling opens the panel, so the
        // "closed" expectations (button reads "Show") cannot hold on arrival.
        let machine = try ScenarioStateMachine(
            initial: "closed",
            states: [MachineState("closed", [Expectation("disclosure").text("Show")])],
            transitions: [Transition(from: "closed", action: .toggle("disclosure"), to: "closed")]
        )
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed", "closed"])

        XCTAssertEqual(result.status, .fail, result.summary())
        XCTAssertEqual(result.steps.count, 2, "entry passes, the lying transition fails")
        XCTAssertEqual(result.steps[0].status, .pass)
        XCTAssertEqual(result.steps[1].status, .fail)
        XCTAssertTrue(
            result.steps[1].verdict.findings.contains {
                $0.rule == Expectation.id && $0.nodeID == "disclosure"
            },
            "the failure must cite the element that disproved arrival: "
                + "\(result.steps[1].verdict.findings.map(\.message))"
        )
        // The walk names where it actually got to, which is what makes a red
        // debuggable — the failing step's own `to` is where it MEANT to be.
        XCTAssertEqual(result.lastVerifiedState, "closed")
    }

    /// An expectation naming an element that is not in the tree must fail, not
    /// pass vacuously. This is the missing-subject shape one layer up: a state
    /// whose distinguishing element was renamed would otherwise stop testing.
    @MainActor
    func testAStateNamingAnAbsentElementFailsRatherThanPassingVacuously() async throws {
        let machine = try ScenarioStateMachine(
            initial: "closed",
            states: [MachineState("closed", [Expectation("panel-body").visible])],
            transitions: []
        )
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed"])

        XCTAssertEqual(result.status, .fail, result.summary())
        XCTAssertEqual(result.steps.count, 1, "the entry check alone")
        XCTAssertTrue(
            result.steps[0].verdict.findings.contains {
                $0.message.contains("no such element")
            },
            "expected a missing-subject finding, got "
                + "\(result.steps[0].verdict.findings.map(\.message))"
        )
    }

    /// A failing entry check must stop the walk: driving actions from a state
    /// the UI is not in makes every later finding describe a screen nobody
    /// asked about.
    @MainActor
    func testAFailingEntryCheckStopsTheWalkBeforeAnyAction() async throws {
        let machine = try ScenarioStateMachine(
            initial: "closed",
            states: [
                // Wrong from the first frame: the button reads "Show" when closed.
                MachineState("closed", [Expectation("disclosure").text("Hide")]),
                MachineState("open", [Expectation("panel-body").visible]),
            ],
            transitions: [Transition(from: "closed", action: .toggle("disclosure"), to: "open")]
        )
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed", "open"])

        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.steps.count, 1, "no transition may run after a bad entry")
        XCTAssertTrue(result.stoppedEarly)
        XCTAssertNil(result.lastVerifiedState, "nothing was ever verified")
    }

    /// A path whose graph does not support it is a defect in the TEST, so it
    /// throws rather than producing a FAIL verdict — conflating the two would
    /// let a typo'd path read as a product bug.
    @MainActor
    func testAnUnwalkablePathThrowsRatherThanReportingAProductFailure() async throws {
        let machine = try panelMachine()
        let harness = Harness(scenario: PanelScenario())

        do {
            _ = try await harness.walk(machine, path: ["closed", "closed"])
            XCTFail("expected a PathError")
        } catch let error as ScenarioStateMachine.PathError {
            XCTAssertEqual(error, .noTransition(from: "closed", to: "closed"))
        }
    }

    /// Multi-path walks must not stop at the first red — the value of a path
    /// table is knowing how many paths are broken, and truncating it turns
    /// "both are broken" into the more comforting "one is broken".
    @MainActor
    func testEveryPathIsWalkedEvenAfterOneFails() async throws {
        let machine = try ScenarioStateMachine(
            initial: "closed",
            states: [
                MachineState("closed", [Expectation("disclosure").text("Show")]),
                // Deliberately wrong: arriving "open" claims the button still
                // reads "Show", which toggling has just falsified.
                MachineState("open", [Expectation("disclosure").text("Show")]),
            ],
            transitions: [
                Transition(from: "closed", action: .toggle("disclosure"), to: "open"),
                Transition(from: "open", action: .toggle("disclosure"), to: "closed"),
            ]
        )

        let results = try await Harness.walk(
            scenario: PanelScenario(),
            machine: machine,
            paths: [["closed", "open"], ["closed", "open", "closed"]]
        )

        XCTAssertEqual(results.count, 2, "a failing path must not truncate the table")
        XCTAssertTrue(results.allSatisfy { $0.status == .fail })
    }

    /// Each path in a multi-path walk starts from a FRESH render. Reusing one
    /// harness would make each result depend on the order the paths are listed
    /// in, while still reporting each path's own name — a wrong answer
    /// indistinguishable from the right one.
    @MainActor
    func testEachPathStartsFromAFreshRenderRatherThanWhereTheLastOneEnded() async throws {
        let machine = try panelMachine()

        // The first path leaves the panel OPEN. If the second path reused that
        // host, its entry check ("closed": button reads "Show") would fail.
        let results = try await Harness.walk(
            scenario: PanelScenario(),
            machine: machine,
            paths: [["closed", "open"], ["closed", "open"]]
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[1].status, .pass, results[1].summary())
        XCTAssertEqual(results[1].steps.first?.status, .pass, "entry must see a fresh render")
    }

    // MARK: - Evidence

    /// A step's label must name the move, not just the destination — a report
    /// reading "open" tells nobody which action was supposed to get there.
    @MainActor
    func testStepLabelsNameTheMoveThatProducedThem() async throws {
        let machine = try panelMachine()
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed", "open"])

        XCTAssertEqual(result.steps[0].label, "(entry) closed")
        XCTAssertEqual(result.steps[1].label, "closed --toggle(disclosure)--> open")
    }

    /// A walk's summary must show the failing step AND its findings — a summary
    /// that only reports PASS/FAIL sends the reader back to the debugger, which
    /// is the cycle this product exists to replace.
    @MainActor
    func testTheSummaryCitesTheFindingThatFailedAStep() async throws {
        let machine = try ScenarioStateMachine(
            initial: "closed",
            states: [MachineState("closed", [Expectation("disclosure").text("Hide")])],
            transitions: []
        )
        let harness = Harness(scenario: PanelScenario())

        let summary = try await harness.walk(machine, path: ["closed"]).summary()

        XCTAssertTrue(summary.contains("FAIL"), summary)
        XCTAssertTrue(summary.contains("expectation"), summary)
        XCTAssertTrue(summary.contains("Hide"), "the summary must quote the expected text: \(summary)")
    }

    /// Lint findings and arrival expectations land in ONE verdict per step. Two
    /// verdicts would let a caller read the passing one and miss the other.
    @MainActor
    func testAStepCarriesBothItsLintFindingsAndItsArrivalCheck() async throws {
        let machine = try panelMachine()
        let harness = Harness(scenario: PanelScenario())

        let result = try await harness.walk(machine, path: ["closed", "open"])
        let transitionStep = try XCTUnwrap(result.steps.last)

        XCTAssertNotNil(transitionStep.step, "a transition step carries its act-and-observe evidence")
        // The delta is what makes a step reviewable without re-rendering: the
        // panel body appears, so the move is visible in the tree diff.
        let delta = try XCTUnwrap(transitionStep.verdict.delta)
        XCTAssertFalse(delta.isEmpty, "opening the panel must show up as a tree delta")
    }

    /// `ProbeAction.description` is spelled by hand rather than derived from the
    /// enum, because a walk report keyed on a compiler-generated form would not
    /// survive a toolchain upgrade. Pinned so the vocabulary cannot drift
    /// silently — it is also the ambiguity key a machine validates on.
    func testActionDescriptionsAreStableAndCarryTheirValues() {
        XCTAssertEqual(ProbeAction.tap("go").description, "tap(go)")
        XCTAssertEqual(ProbeAction.toggle("flag").description, "toggle(flag)")
        XCTAssertEqual(ProbeAction.setText("f", "hi").description, #"setText(f, "hi")"#)
        XCTAssertEqual(ProbeAction.setSlider("s", 0.5).description, "setSlider(s, 0.5)")
        XCTAssertEqual(ProbeAction.custom("c") { _ in }.description, "custom(c)")
    }
}
