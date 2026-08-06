// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 3 Task 4: atomic act-and-observe. One call captures before/after trees,
// settles, diffs, and lints — the API agents live on.
import Foundation
import VerdictUIKernel

// MARK: - Step / flow results

/// Complete evidence from a single ``Harness/perform(_:)`` call.
public struct StepResult: Equatable, Sendable {
    /// Probe id the action targeted (evidence key even when the act failed).
    public let probeID: String
    /// Tree immediately before the action.
    public let before: SemanticNode
    /// Tree after settle, or `nil` when the act never ran / settle timed out
    /// before a reliable after-tree was captured.
    public let after: SemanticNode?
    /// Settle outcome for this step (``.settled(after: .zero)`` when settle was
    /// skipped because the action itself failed).
    public let settle: SettleResult
    /// ``TreeDiff`` from ``before`` to ``after`` (empty when there is no after).
    public let delta: TreeDelta
    /// Lint + act/settle findings. Always carries ``delta`` when one was computed.
    public let verdict: Verdict
    /// Wall-clock milliseconds for the whole step (capture → act → settle → lint).
    public let elapsedMs: Double

    /// Derived from ``verdict`` — any error finding makes the step a FAIL.
    public var status: Verdict.Status { verdict.status }
}

/// Batched ``Harness/run(_:)`` result with per-step evidence and early-exit flag.
public struct FlowResult: Equatable, Sendable {
    /// Steps that ran (may be shorter than the requested flow on early FAIL exit).
    public let steps: [StepResult]
    /// `true` when a FAIL step stopped the flow before every action ran.
    public let stoppedEarly: Bool

    /// FAIL if any step failed; otherwise PASS.
    public var status: Verdict.Status {
        steps.contains { $0.status == .fail } ? .fail : .pass
    }

    /// Sum of per-step wall-clock costs.
    public var totalElapsedMs: Double {
        steps.reduce(0) { $0 + $1.elapsedMs }
    }
}

// MARK: - Harness

/// Owns an ``OracleHost`` and exposes atomic act-and-observe.
///
/// `perform` is the agent-facing unit: tree → act → settle → tree → diff → rules
/// → ``Verdict`` + ``TreeDelta`` in one call. `run` batches steps and stops on
/// the first FAIL.
@MainActor
public final class Harness {
    /// Rule name for ``ProbeActionError`` FAIL findings.
    public static let actionErrorRule = "probe-action"

    /// Rule name when ``OracleHost/currentTree()`` throws inside `perform`.
    public static let hostErrorRule = "oracle-host"

    /// Host that renders the scenario and owns settle / apply.
    public let host: OracleHost

    /// Lint rules evaluated on the after-tree (default: ``RuleEngine/standardRules``).
    public var rules: [any LintRule]

    /// When true, embed the after-tree in each step's ``Verdict``.
    public var includeTree: Bool

    /// Create a harness wrapping an existing host.
    public init(
        host: OracleHost,
        rules: [any LintRule] = RuleEngine.standardRules,
        includeTree: Bool = false
    ) {
        self.host = host
        self.rules = rules
        self.includeTree = includeTree
    }

    /// Convenience: build a host for `scenario` and wrap it.
    public convenience init<Scenario: VerdictScenario>(
        scenario: Scenario,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        settlePolicy: SettlePolicy = .skipAnimations,
        clock: VerdictClock = VerdictClock(),
        rules: [any LintRule] = RuleEngine.standardRules,
        includeTree: Bool = false
    ) {
        self.init(
            host: OracleHost(
                scenario: scenario,
                viewport: viewport,
                deadline: deadline,
                settlePolicy: settlePolicy,
                clock: clock
            ),
            rules: rules,
            includeTree: includeTree
        )
    }

    /// Capture tree → act → settle → capture → diff → lint. Never hangs.
    ///
    /// Settle timeout and unknown-probe errors become FAIL verdicts with cited
    /// evidence — they are not thrown, so agents always get a ``StepResult``.
    public func perform(
        _ action: ProbeAction,
        timeout: Duration = Quiescence.defaultTimeout
    ) async -> StepResult {
        let started = ContinuousClock.now
        let probeID = action.probeID

        let before: SemanticNode
        do {
            before = try await host.currentTree()
        } catch {
            let empty = SemanticNode(
                id: "",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 0, height: 0)
            )
            let settleMs = started.duration(to: .now).asMilliseconds
            let verdict = Verdict(
                scenario: host.scenarioName,
                findings: [
                    Finding(
                        rule: Self.hostErrorRule,
                        severity: .error,
                        nodeID: probeID,
                        message: "failed to capture before-tree: \(error)",
                        suggestion: "Raise OracleHost.deadline or fix the scenario body."
                    )
                ],
                tree: nil,
                delta: TreeDelta(),
                timing: Verdict.Timing(settleMs: settleMs)
            )
            return StepResult(
                probeID: probeID,
                before: empty,
                after: nil,
                settle: .timedOut(lastDelta: TreeDelta()),
                delta: TreeDelta(),
                verdict: verdict,
                elapsedMs: settleMs
            )
        }

        do {
            try host.apply(action)
        } catch let error as ProbeActionError {
            let elapsedMs = started.duration(to: .now).asMilliseconds
            let verdict = Verdict(
                scenario: host.scenarioName,
                findings: [
                    Finding(
                        rule: Self.actionErrorRule,
                        severity: .error,
                        nodeID: error.probeID,
                        message: error.description,
                        suggestion: """
                            Register a compatible binding with \
                            .verdictProbe(..., action:) for this probe id.
                            """
                    )
                ],
                tree: includeTree ? before : nil,
                delta: TreeDelta(),
                timing: Verdict.Timing(settleMs: 0, evaluateMs: 0)
            )
            return StepResult(
                probeID: probeID,
                before: before,
                after: before,
                settle: .settled(after: .zero),
                delta: TreeDelta(),
                verdict: verdict,
                elapsedMs: elapsedMs
            )
        } catch {
            let elapsedMs = started.duration(to: .now).asMilliseconds
            let verdict = Verdict(
                scenario: host.scenarioName,
                findings: [
                    Finding(
                        rule: Self.actionErrorRule,
                        severity: .error,
                        nodeID: probeID,
                        message: "action failed: \(error)",
                        suggestion: nil
                    )
                ],
                tree: includeTree ? before : nil,
                delta: TreeDelta(),
                timing: Verdict.Timing(settleMs: 0)
            )
            return StepResult(
                probeID: probeID,
                before: before,
                after: before,
                settle: .settled(after: .zero),
                delta: TreeDelta(),
                verdict: verdict,
                elapsedMs: elapsedMs
            )
        }

        let settle = await host.settle(timeout: timeout)
        let settleMs: Double
        if case .settled(let after) = settle {
            settleMs = after.asMilliseconds
        } else {
            settleMs = timeout.asMilliseconds
        }

        if case .timedOut = settle {
            let after = host.latestTree
            let delta: TreeDelta
            if let after {
                delta = TreeDiff.compute(before: before, after: after)
            } else if case .timedOut(let lastDelta) = settle {
                delta = lastDelta
            } else {
                delta = TreeDelta()
            }
            var verdict = host.timeoutVerdict(from: settle, settleMs: settleMs)
                ?? Verdict(
                    scenario: host.scenarioName,
                    findings: [
                        Finding(
                            rule: Quiescence.timeoutRule,
                            severity: .error,
                            nodeID: probeID,
                            message: "settle timed out",
                            suggestion: nil
                        )
                    ],
                    tree: includeTree ? after : nil,
                    delta: delta,
                    timing: Verdict.Timing(settleMs: settleMs)
                )
            if includeTree { verdict.tree = after }
            verdict.delta = delta
            let elapsedMs = started.duration(to: .now).asMilliseconds
            return StepResult(
                probeID: probeID,
                before: before,
                after: after,
                settle: settle,
                delta: delta,
                verdict: verdict,
                elapsedMs: elapsedMs
            )
        }

        let after: SemanticNode
        do {
            after = try await host.currentTree()
        } catch {
            let elapsedMs = started.duration(to: .now).asMilliseconds
            let verdict = Verdict(
                scenario: host.scenarioName,
                findings: [
                    Finding(
                        rule: Self.hostErrorRule,
                        severity: .error,
                        nodeID: probeID,
                        message: "failed to capture after-tree: \(error)",
                        suggestion: "Raise OracleHost.deadline or inspect settle signals."
                    )
                ],
                tree: nil,
                delta: TreeDelta(),
                timing: Verdict.Timing(settleMs: settleMs)
            )
            return StepResult(
                probeID: probeID,
                before: before,
                after: nil,
                settle: settle,
                delta: TreeDelta(),
                verdict: verdict,
                elapsedMs: elapsedMs
            )
        }

        let delta = TreeDiff.compute(before: before, after: after)
        let context = LintContext.macOS(
            viewport: after.frame,
            scenario: host.scenarioName
        )
        var verdict = RuleEngine.run(
            rules: rules,
            on: after,
            context: context,
            includeTree: includeTree
        )
        verdict.delta = delta
        verdict.timing.settleMs = settleMs
        let elapsedMs = started.duration(to: .now).asMilliseconds
        return StepResult(
            probeID: probeID,
            before: before,
            after: after,
            settle: settle,
            delta: delta,
            verdict: verdict,
            elapsedMs: elapsedMs
        )
    }

    /// Run `flow` in order; stop on the first FAIL step.
    public func run(
        _ flow: [ProbeAction],
        timeout: Duration = Quiescence.defaultTimeout
    ) async -> FlowResult {
        var steps: [StepResult] = []
        for action in flow {
            let step = await perform(action, timeout: timeout)
            steps.append(step)
            if step.status == .fail {
                return FlowResult(steps: steps, stoppedEarly: steps.count < flow.count)
            }
        }
        return FlowResult(steps: steps, stoppedEarly: false)
    }
}

// MARK: - Duration helper

private extension Duration {
    /// Milliseconds for ``Verdict/Timing`` (probe-local; kernel's copy is internal).
    var asMilliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}
