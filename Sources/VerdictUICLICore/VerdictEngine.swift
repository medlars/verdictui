// Wave 6: what every CLI command actually does.
//
// The argument-parser types in `Commands.swift` parse and delegate here. This
// file holds no `print` and no `exit` — it returns values — which is what makes
// the whole command surface assertable from a test target rather than only
// through a subprocess.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// Runs scenarios and produces verdicts, trees, sweeps and baseline decisions.
///
/// Holds the registry and the baseline store so a caller (the CLI, the daemon,
/// the MCP server) constructs one of these and asks it questions. The three
/// surfaces then cannot disagree about what `verify` means, which is the
/// failure a second implementation always eventually produces.
public struct VerdictEngine: Sendable {
    /// Scenarios this engine can render.
    public let registry: ScenarioRegistry
    /// Where baselines live.
    public let baselines: BaselineStore

    public init(registry: ScenarioRegistry, baselines: BaselineStore) {
        self.registry = registry
        self.baselines = baselines
    }

    /// Why a request could not be answered.
    ///
    /// Distinct from a FAILING verdict throughout: every case here means the
    /// engine could not look, and a caller must not report any of them as a
    /// statement about the UI.
    public enum EngineError: Error, Equatable, CustomStringConvertible {
        case unknownScenario(name: String, available: [String])
        case renderFailed(scenario: String, reason: String)
        case store(String)

        public var description: String {
            switch self {
            case .unknownScenario(let name, let available):
                let list =
                    available.isEmpty
                    ? "the registry is empty"
                    : "available: \(available.sorted().joined(separator: ", "))"
                return "no scenario named '\(name)' — \(list)"
            case .renderFailed(let scenario, let reason):
                return "could not render '\(scenario)': \(reason)"
            case .store(let message):
                return message
            }
        }
    }

    /// Every registered scenario name, sorted.
    public var scenarioNames: [String] { registry.names.sorted() }

    /// Look up an entry or say what was available instead.
    ///
    /// The available list travels with the error on purpose: "no scenario named
    /// 'chekcout'" is a dead end, and the same message plus `checkout` in the
    /// list answers the question the user actually has.
    private func entry(named name: String) throws -> ScenarioEntry {
        guard let entry = registry.entry(named: name) else {
            throw EngineError.unknownScenario(name: name, available: registry.names)
        }
        return entry
    }

    /// Render `scenario` and return its semantic tree.
    @MainActor
    public func render(
        scenario name: String,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) async throws -> SemanticNode {
        let entry = try entry(named: name)
        let host = entry.host(viewport: viewport, deadline: deadline)
        do {
            return try await host.currentTree()
        } catch {
            throw EngineError.renderFailed(scenario: name, reason: String(describing: error))
        }
    }

    /// Render `scenario` and judge it.
    ///
    /// - Parameters:
    ///   - rules: which rules to run. Defaults to the standard set.
    ///   - baseline: also compare against the recorded baseline, adding drift
    ///     findings to the verdict.
    @MainActor
    public func verify(
        scenario name: String,
        rules: [any LintRule] = RuleEngine.standardRules,
        againstBaseline useBaseline: Bool = false,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        includeTree: Bool = false
    ) async throws -> Verdict {
        let tree = try await render(scenario: name, viewport: viewport, deadline: deadline)
        let context = LintContext.macOS(viewport: tree.frame, scenario: name)
        var verdict = RuleEngine.run(
            rules: rules,
            on: tree,
            context: context,
            includeTree: includeTree
        )

        guard useBaseline else { return verdict }

        // A baseline comparison is ADDITIVE to the lint verdict, never a
        // replacement: drift and a rule violation are different claims, and a
        // screen can be both unchanged since the last accept and wrong.
        let recorded: Baseline
        do {
            recorded = try baselines.load(scenario: name)
        } catch {
            throw EngineError.store(String(describing: error))
        }

        let comparison = BaselineCheck.compare(tree, to: recorded, context: context)
        verdict.findings.append(contentsOf: comparison.findings)
        verdict.status = Verdict.Status.derived(from: verdict.findings)
        return verdict
    }

    /// Compare `scenario` against its baseline without linting it.
    @MainActor
    public func baselineDiff(scenario name: String) async throws -> BaselineComparison {
        let tree = try await render(scenario: name)
        let context = LintContext.macOS(viewport: tree.frame, scenario: name)
        do {
            let recorded = try baselines.load(scenario: name)
            return BaselineCheck.compare(tree, to: recorded, context: context)
        } catch {
            throw EngineError.store(String(describing: error))
        }
    }

    /// Record `scenario`'s current render as its baseline.
    ///
    /// The one destructive operation the CLI exposes. The guard lives in
    /// ``BaselineStore`` rather than here so the daemon and the MCP server
    /// cannot route around it by calling the store directly.
    @MainActor
    public func updateBaseline(
        scenario name: String,
        accepted: Bool
    ) async throws -> BaselineStore.UpdateOutcome {
        let tree = try await render(scenario: name)
        do {
            return try baselines.update(scenario: name, tree: tree, accepted: accepted)
        } catch {
            throw EngineError.store(String(describing: error))
        }
    }

    /// Render `scenario` across `variants` and return the report.
    ///
    /// Cells are rendered here rather than through ``Sweep/run(rules:deadline:includeTrees:)``
    /// for one reason: `Sweep` is generic over a CONCRETE scenario type, and a
    /// registry entry has already erased that — which is the same constraint
    /// that made `ScenarioEntry` store a closure in the first place. The
    /// per-cell handling is kept byte-for-byte identical to `Sweep.run`'s,
    /// including recording an unrenderable cell as unmeasured rather than as a
    /// pass, and `testTheEngineAndSweepAgreeOnAnUnmeasuredCell` holds the two
    /// together so this copy cannot drift into calling a failed render clean.
    @MainActor
    public func sweep(
        scenario name: String,
        variants: [Variant],
        rules: [any LintRule] = RuleEngine.standardRules,
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) async throws -> SweepReport {
        let entry = try entry(named: name)
        var cells: [SweepCell] = []

        for variant in variants {
            let host = entry.host(
                viewport: variant.viewport,
                deadline: deadline,
                variant: variant
            )
            do {
                let tree = try await host.currentTree()
                let verdict = RuleEngine.run(
                    rules: rules,
                    on: tree,
                    context: LintContext.macOS(
                        viewport: tree.frame,
                        scenario: "\(name) [\(variant.name)]"
                    )
                )
                cells.append(SweepCell(variant: variant, verdict: verdict, error: nil))
            } catch {
                cells.append(
                    SweepCell(variant: variant, verdict: nil, error: String(describing: error))
                )
            }
        }
        return SweepReport(scenario: name, cells: cells)
    }
}
