// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 5 Task 5: state-machine scenarios. A screen is described as named states
// and the actions that move between them; `walk` drives a path and produces a
// verdict per step, with the ARRIVAL checked at every one.
import Foundation
import VerdictUIKernel

/// One named state of a screen, and how to recognise it.
///
/// The `expectations` are not decoration — they are what makes a transition
/// target an OBSERVATION rather than a claim. A machine whose states are only
/// names can report "walked login → dashboard → settings" while the app never
/// left the login screen: every action would still be applied, every settle
/// would still succeed, and every step would still be PASS. That is the
/// false-green this product exists to prevent, so a state with no expectations
/// is rejected at construction (see ``ScenarioStateMachine/ValidationError``)
/// rather than silently producing an unfalsifiable walk.
public struct MachineState: Sendable {
    /// Stable name — used in paths, transitions, and step evidence.
    public let name: String

    /// What must be true of the tree when this state is on screen.
    public let expectations: ExpectationSet

    /// - Parameters:
    ///   - name: the state's identity within its machine.
    ///   - expectations: at least one claim that distinguishes this state from
    ///     the others. Passing an empty list is a construction error, not a
    ///     lenient default.
    public init(_ name: String, _ expectations: [Expectation]) {
        self.name = name
        self.expectations = ExpectationSet(name, expectations)
    }
}

/// A move between two named states, driven by one ``ProbeAction``.
///
/// Deliberately NOT `Sendable`: ``ProbeAction/custom(_:_:)`` carries a
/// `@MainActor` closure, so claiming the conformance would need an
/// `@unchecked` escape hatch that suppresses the compiler's correct objection
/// rather than answering it. A machine is authored and walked on the main actor,
/// where the harness already lives, so nothing needs to send one across an
/// isolation boundary.
public struct Transition {
    /// State this transition departs from.
    public let from: String
    /// State the UI must be in once the action has settled.
    public let to: String
    /// The action that performs the move.
    public let action: ProbeAction

    public init(from: String, action: ProbeAction, to: String) {
        self.from = from
        self.to = to
        self.action = action
    }

    /// How a step names this move in evidence: `login --tap(sign-in)--> dashboard`.
    public var label: String {
        "\(from) --\(action.description)--> \(to)"
    }
}

/// A named screen described as states plus the transitions between them.
///
/// ```swift
/// let machine = try ScenarioStateMachine(
///     initial: "closed",
///     states: [
///         MachineState("closed", [Expectation("open-button").visible]),
///         MachineState("open", [Expectation("panel").visible]),
///     ],
///     transitions: [
///         Transition(from: "closed", action: .tap("open-button"), to: "open"),
///         Transition(from: "open", action: .tap("close-button"), to: "closed"),
///     ]
/// )
/// ```
///
/// ## Why the graph is validated at construction
///
/// Every structural error here — a transition naming a state that does not
/// exist, a duplicate state, a state with no expectations, an initial state
/// outside the set — produces a walk that RUNS and REPORTS rather than one that
/// fails. A transition to an unknown state would drive the action and then have
/// nothing to check on arrival; a state with no expectations makes every arrival
/// vacuously correct. Both read as green. Rejecting the machine when it is built
/// converts a silent wrong answer into a loud refusal at the only point where
/// the author is still looking at the graph.
/// Not `Sendable`, for the reason ``Transition`` is not — it holds transitions,
/// which hold actions, which may carry a `@MainActor` closure.
public struct ScenarioStateMachine {
    /// Why a machine could not be built.
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        /// Two states share a name — a path naming it would be ambiguous.
        case duplicateState(String)
        /// A state carries no expectations, so arriving in it asserts nothing.
        case stateHasNoExpectations(String)
        /// The initial state is not among ``ScenarioStateMachine/states``.
        case unknownInitialState(String)
        /// A transition names a state the machine does not define.
        case unknownTransitionState(transition: String, state: String)
        /// Two transitions leave the same state with the same action, so which
        /// one a walk took would depend on declaration order rather than on the
        /// author's intent.
        case ambiguousTransition(from: String, action: String)
        /// The machine defines no states at all.
        case empty

        public var description: String {
            switch self {
            case .duplicateState(let name):
                "duplicate state '\(name)'"
            case .stateHasNoExpectations(let name):
                "state '\(name)' has no expectations, so arriving in it would assert nothing"
            case .unknownInitialState(let name):
                "initial state '\(name)' is not defined"
            case .unknownTransitionState(let transition, let state):
                "transition \(transition) names undefined state '\(state)'"
            case .ambiguousTransition(let from, let action):
                "two transitions leave '\(from)' on \(action)"
            case .empty:
                "a state machine needs at least one state"
            }
        }
    }

    /// Name of the state the scenario renders in before any action.
    public let initial: String
    /// Every state, keyed by name.
    public let states: [String: MachineState]
    /// Every transition, in declaration order.
    public let transitions: [Transition]

    /// Build and validate a machine.
    ///
    /// - Throws: ``ValidationError`` for any structural defect — see the type
    ///   documentation for why these are errors rather than tolerated.
    public init(
        initial: String,
        states: [MachineState],
        transitions: [Transition]
    ) throws {
        guard !states.isEmpty else { throw ValidationError.empty }

        var byName: [String: MachineState] = [:]
        for state in states {
            guard byName[state.name] == nil else {
                throw ValidationError.duplicateState(state.name)
            }
            guard !state.expectations.expectations.isEmpty else {
                throw ValidationError.stateHasNoExpectations(state.name)
            }
            byName[state.name] = state
        }

        guard byName[initial] != nil else {
            throw ValidationError.unknownInitialState(initial)
        }

        var seenEdges: Set<String> = []
        for transition in transitions {
            for endpoint in [transition.from, transition.to] where byName[endpoint] == nil {
                throw ValidationError.unknownTransitionState(
                    transition: transition.label,
                    state: endpoint
                )
            }
            let edge = "\(transition.from)\u{1}\(transition.action.description)"
            guard seenEdges.insert(edge).inserted else {
                throw ValidationError.ambiguousTransition(
                    from: transition.from,
                    action: transition.action.description
                )
            }
        }

        self.initial = initial
        self.states = byName
        self.transitions = transitions
    }

    /// The transition leaving `state` that lands in `target`, if one exists.
    public func transition(from state: String, to target: String) -> Transition? {
        transitions.first { $0.from == state && $0.to == target }
    }

    /// Every state reachable from ``initial`` by following transitions.
    ///
    /// Exposed because an unreachable state is a real defect a caller may want
    /// to assert against, and computing it needs the graph — but it is NOT
    /// enforced at construction: a machine under active authoring legitimately
    /// has an orphan state for a minute, and refusing to build it would make the
    /// type hostile to the workflow it exists to serve.
    public var reachableStates: Set<String> {
        var seen: Set<String> = [initial]
        var frontier = [initial]
        while let current = frontier.popLast() {
            for transition in transitions where transition.from == current {
                if seen.insert(transition.to).inserted {
                    frontier.append(transition.to)
                }
            }
        }
        return seen
    }

    /// States defined but not reachable from ``initial``.
    public var unreachableStates: [String] {
        let reachable = reachableStates
        return states.keys.filter { !reachable.contains($0) }.sorted()
    }

    /// Expand `path` — a sequence of state names starting at ``initial`` — into
    /// the transitions that walk it.
    ///
    /// - Throws: ``PathError`` when the path does not start at ``initial`` or
    ///   asks for a move the graph does not define. A path that cannot be walked
    ///   must not silently become a shorter one.
    public func resolve(path: [String]) throws -> [Transition] {
        guard let start = path.first else { return [] }
        guard start == initial else {
            throw PathError.doesNotStartAtInitial(given: start, initial: initial)
        }

        var resolved: [Transition] = []
        for (from, to) in zip(path, path.dropFirst()) {
            guard let transition = transition(from: from, to: to) else {
                throw PathError.noTransition(from: from, to: to)
            }
            resolved.append(transition)
        }
        return resolved
    }

    /// Why a requested path could not be walked.
    public enum PathError: Error, Equatable, CustomStringConvertible {
        /// The path's first element is not the machine's initial state.
        case doesNotStartAtInitial(given: String, initial: String)
        /// The graph defines no transition between two consecutive states.
        case noTransition(from: String, to: String)
        /// A state the graph names could not be resolved to its definition.
        ///
        /// Unreachable through the public initialiser, which rejects every
        /// unknown name — this case exists so the walk can RESOLVE states up
        /// front instead of force-unwrapping them mid-walk. A crash is a worse
        /// answer than an error even for an invariant that holds today, because
        /// the invariant is enforced in a different type than the one relying
        /// on it.
        case unresolvableState(String)

        public var description: String {
            switch self {
            case .doesNotStartAtInitial(let given, let initial):
                "path starts at '\(given)' but the machine's initial state is '\(initial)'"
            case .noTransition(let from, let to):
                "no transition from '\(from)' to '\(to)'"
            case .unresolvableState(let name):
                "state '\(name)' is named by the graph but has no definition"
            }
        }
    }
}

// MARK: - Walk results

/// One step of a walk: the move attempted, and everything observed doing it.
/// Not `Sendable` — it carries the ``ProbeAction`` that produced it, which may
/// hold a `@MainActor` closure. ``WalkResult/summary()`` renders everything a
/// caller needs to move across an isolation boundary as a `String`.
public struct WalkStep {
    /// State the UI was in before this step. `nil` for the entry check, which
    /// happens before any transition.
    public let from: String?
    /// State the UI is expected to be in after this step.
    public let to: String
    /// The action taken, or `nil` for the entry check.
    public let action: ProbeAction?
    /// Act-and-observe evidence, or `nil` for the entry check (which observes
    /// without acting).
    public let step: StepResult?
    /// The verdict for this step: lint findings plus the arrival expectations.
    public let verdict: Verdict

    /// How this step reads in a report.
    public var label: String {
        guard let from, let action else { return "(entry) \(to)" }
        return "\(from) --\(action.description)--> \(to)"
    }

    /// Derived from ``verdict``.
    public var status: Verdict.Status { verdict.status }
}

/// The result of walking one path through a machine.
/// Not `Sendable` — see ``WalkStep``.
public struct WalkResult {
    /// Scenario walked.
    public let scenario: String
    /// The path requested, as state names.
    public let path: [String]
    /// Steps that ran — shorter than `path` when a step failed and stopped it.
    public let steps: [WalkStep]
    /// True when a failing step ended the walk before the path was exhausted.
    public let stoppedEarly: Bool

    /// FAIL if any step failed.
    public var status: Verdict.Status {
        steps.contains { $0.status == .fail } ? .fail : .pass
    }

    /// The last state whose arrival was verified, or `nil` if even entry failed.
    ///
    /// This is what makes a failed walk debuggable: it names where the UI
    /// actually got to, which is rarely where the failing step says it was going.
    public var lastVerifiedState: String? {
        steps.last { $0.status == .pass }?.to
    }

    /// Sum of per-step wall-clock costs (entry check included).
    public var totalElapsedMs: Double {
        steps.reduce(0) { $0 + ($1.step?.elapsedMs ?? 0) }
    }

    /// A one-line-per-step summary for a report or a CLI.
    public func summary() -> String {
        var lines = ["\(scenario): \(path.joined(separator: " → "))"]
        for step in steps {
            let mark = step.status == .pass ? "PASS" : "FAIL"
            lines.append("  [\(mark)] \(step.label)")
            for finding in step.verdict.findings where finding.severity == .error {
                lines.append("         \(finding.rule): \(finding.message)")
            }
        }
        if stoppedEarly {
            lines.append("  (stopped early — \(steps.count) of \(path.count) states reached)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Walking

extension Harness {
    /// Rule id carried by findings a walk itself produces (as opposed to lint
    /// findings from the rules, or `expectation` findings from a state).
    public static let walkRule = "state-walk"

    /// Drive `path` through `machine`, verifying arrival at every state.
    ///
    /// The entry state is checked BEFORE any action. A walk that starts in the
    /// wrong state and skips that check reports its first TRANSITION as the
    /// failure, which sends debugging at an innocent action — the entry check
    /// makes "the scenario did not render the state you said it starts in" its
    /// own named step.
    ///
    /// Stops at the first failing step. Continuing past one would drive actions
    /// from a state the UI is not in, so every later finding would describe a
    /// screen nobody asked for; the failure is reported once, where it happened.
    ///
    /// - Parameters:
    ///   - machine: the validated graph.
    ///   - path: state names, beginning at ``ScenarioStateMachine/initial``.
    ///   - timeout: settle budget per transition.
    /// - Throws: ``ScenarioStateMachine/PathError`` when the path is not walkable
    ///   on this graph. Thrown rather than reported as a FAIL because it is a
    ///   defect in the TEST, not in the UI, and conflating the two would let a
    ///   typo'd path read as a product bug.
    public func walk(
        _ machine: ScenarioStateMachine,
        path: [String],
        timeout: Duration = Quiescence.defaultTimeout
    ) async throws -> WalkResult {
        let transitions = try machine.resolve(path: path)

        var steps: [WalkStep] = []

        // Every state is resolved to its `MachineState` HERE, where a miss is
        // still throwable. Passing names down and looking them up mid-walk would
        // need a force-unwrap (a crash if the invariant ever breaks) or a
        // defensive branch no test can enter, because the initialiser has
        // already rejected every unknown name `resolve` could return.
        guard let initialState = machine.states[machine.initial] else {
            throw ScenarioStateMachine.PathError.unresolvableState(machine.initial)
        }
        var arrivals: [MachineState] = []
        for transition in transitions {
            guard let state = machine.states[transition.to] else {
                throw ScenarioStateMachine.PathError.unresolvableState(transition.to)
            }
            arrivals.append(state)
        }

        // Entry check: observe without acting.
        let entry = await verifyArrival(
            state: initialState,
            after: nil,
            from: nil,
            action: nil
        )
        steps.append(entry)
        if entry.status == .fail {
            return WalkResult(
                scenario: host.scenarioName,
                path: path,
                steps: steps,
                stoppedEarly: !transitions.isEmpty
            )
        }

        for (index, transition) in transitions.enumerated() {
            let result = await perform(transition.action, timeout: timeout)
            let arrival = await verifyArrival(
                state: arrivals[index],
                after: result,
                from: transition.from,
                action: transition.action
            )
            steps.append(arrival)
            if arrival.status == .fail {
                return WalkResult(
                    scenario: host.scenarioName,
                    path: path,
                    steps: steps,
                    stoppedEarly: index + 1 < transitions.count
                )
            }
        }

        return WalkResult(
            scenario: host.scenarioName,
            path: path,
            steps: steps,
            stoppedEarly: false
        )
    }

    /// Walk several paths in order, returning one result each.
    ///
    /// Paths are independent claims, so a failing one does NOT stop the rest:
    /// the value of a multi-path walk is the coverage table, and truncating it
    /// at the first red turns "3 of 5 paths are broken" into "1 path is broken",
    /// which is a different and more comforting answer than the truth.
    ///
    /// Each path gets a FRESH harness, because a path that begins where the
    /// previous one ended is not the path the caller asked for. Reusing one
    /// harness would make every result after the first depend on the order the
    /// paths happen to be listed in — and it would still report each path's own
    /// name, so the wrong answer would be indistinguishable from the right one.
    ///
    /// A static rather than an instance method for the same reason: an instance
    /// method would imply the receiver's host is used, which is exactly the
    /// thing that must NOT happen.
    public static func walk<Scenario: VerdictScenario>(
        scenario: Scenario,
        machine: ScenarioStateMachine,
        paths: [[String]],
        viewport: Size? = nil,
        rules: [any LintRule] = RuleEngine.standardRules,
        timeout: Duration = Quiescence.defaultTimeout
    ) async throws -> [WalkResult] {
        var results: [WalkResult] = []
        for path in paths {
            let harness = Harness(scenario: scenario, viewport: viewport, rules: rules)
            results.append(try await harness.walk(machine, path: path, timeout: timeout))
        }
        return results
    }

    /// Check the arrival expectations for `state` against the current tree.
    ///
    /// Combines three sources into ONE verdict per step — the step's own lint
    /// findings, the arrival expectations, and any host error — because a step
    /// with two verdicts would let a caller read the passing one.
    private func verifyArrival(
        state machineState: MachineState,
        after result: StepResult?,
        from: String?,
        action: ProbeAction?
    ) async -> WalkStep {
        let state = machineState.name
        let tree: SemanticNode?
        var findings: [Finding] = result?.verdict.findings ?? []

        if let result {
            tree = result.after
        } else {
            do {
                tree = try await host.currentTree()
            } catch {
                tree = nil
                findings.append(
                    Finding(
                        rule: Self.walkRule,
                        severity: .error,
                        nodeID: state,
                        message: "could not capture the tree for entry state '\(state)': \(error)",
                        suggestion: "raise OracleHost.deadline or fix the scenario body"
                    )
                )
            }
        }

        if let tree {
            let context = LintContext.macOS(
                viewport: tree.frame,
                scenario: "\(host.scenarioName) [\(state)]"
            )
            findings.append(
                contentsOf: machineState.expectations.evaluate(in: tree, context: context)
            )
        } else if result != nil {
            findings.append(
                Finding(
                    rule: Self.walkRule,
                    severity: .error,
                    nodeID: state,
                    message: "no tree after the move to '\(state)', so arrival is unverified",
                    suggestion: "inspect the step's settle result"
                )
            )
        }

        let verdict = Verdict(
            scenario: host.scenarioName,
            findings: findings,
            tree: includeTree ? tree : nil,
            delta: result?.delta ?? TreeDelta(),
            timing: Verdict.Timing(settleMs: result?.verdict.timing.settleMs ?? 0)
        )

        return WalkStep(
            from: from,
            to: state,
            action: action,
            step: result,
            verdict: verdict
        )
    }
}
