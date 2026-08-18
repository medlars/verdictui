// Wave 6: what every CLI command actually does.
//
// The argument-parser types in `Commands.swift` parse and delegate here. This
// file holds no `print` and no `exit` — it returns values — which is what makes
// the whole command surface assertable from a test target rather than only
// through a subprocess.
import Foundation
import VerdictUIKernel
import VerdictUIProbe
import VerdictUIWitness

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

    /// Which probes in `scenario` accept an act, and which verbs each accepts.
    ///
    /// The discovery half of ``act(scenario:action:rules:viewport:deadline:includeTree:)``.
    /// Without it a caller can only learn actionability by acting and being
    /// refused: `role` says what a node IS, not what the harness can DRIVE, and
    /// a probe may carry `.toggle` with no binding behind it.
    ///
    /// Renders first, because bindings register during view evaluation — a
    /// query before any render reports an empty set, which reads as "nothing
    /// here is actionable" and is a wrong answer rather than an absent one.
    @MainActor
    public func actionableProbes(
        scenario name: String,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) async throws -> [String: [String]] {
        let entry = try entry(named: name)
        let host = entry.host(viewport: viewport, deadline: deadline)
        do {
            _ = try await host.currentTree()
        } catch {
            throw EngineError.renderFailed(scenario: name, reason: String(describing: error))
        }
        return host.actionableProbes
    }

    /// Render `scenario` and capture its pixels alongside its tree.
    ///
    /// Both come from ONE host, so the bitmap and the tree describe a single
    /// layout pass rather than two independent renders that might have settled
    /// differently. That is the whole reason this lives on the engine instead of
    /// being composed by a caller from `render` plus a separate capture.
    ///
    /// The capture goes through the cache when one is supplied, and the result
    /// says whether it hit — a caller reporting a speedup must not have to guess.
    ///
    /// - Throws: ``EngineError/renderFailed(scenario:reason:)`` for a settle
    ///   failure, and the underlying capture error for a bitmap that could not
    ///   be produced. The two are kept distinct because "the screen never
    ///   settled" and "the screen settled and could not be photographed" have
    ///   different fixes.
    @MainActor
    public func renderPixels(
        scenario name: String,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        backend: PixelBackend = .cacheDisplay,
        cache: PixelCache? = nil
    ) async throws -> (tree: SemanticNode, capture: PixelCapture, wasHit: Bool) {
        let entry = try entry(named: name)
        let host = entry.host(viewport: viewport, deadline: deadline)
        let tree: SemanticNode
        do {
            tree = try await host.currentTree()
        } catch {
            throw EngineError.renderFailed(scenario: name, reason: String(describing: error))
        }
        guard let cache else {
            return (tree, try host.capturePixels(backend: backend), false)
        }
        let cached = try host.capturePixelsCached(tree: tree, cache: cache, backend: backend)
        return (tree, cached.capture, cached.wasHit)
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
        includeTree: Bool = false,
        crossValidate: Bool = false
    ) async throws -> Verdict {
        let tree = try await render(scenario: name, viewport: viewport, deadline: deadline)
        let context = LintContext.macOS(viewport: tree.frame, scenario: name)
        var verdict = RuleEngine.run(
            rules: rules,
            on: tree,
            context: context,
            includeTree: includeTree
        )

        // Cross-validation is ADDITIVE, like the baseline check below it: the
        // inner loop's verdict stands, and the external witness can only add
        // findings. It runs BEFORE the baseline comparison so that a verdict
        // carrying both reads in pipeline order.
        if crossValidate {
            let clock = ContinuousClock()
            var findings: [Finding] = []
            let elapsed = clock.measure {
                findings = Self.crossValidationFindings(for: name, tree: tree)
            }
            // Measured on BOTH paths — the successful one and the skipped one.
            // A budget echoed back as a measurement is the defect `no.md` #12
            // spent four attempts failing to pin; here the cost of a failed
            // attempt is real and worth reporting, because "the witness took
            // 4 s to fail" is the difference between a missing grant and a
            // hung host.
            verdict.timing.crossValidateMs = Double(elapsed.components.attoseconds) / 1e15
            verdict.findings.append(contentsOf: findings)
            verdict.status = Verdict.Status.derived(from: verdict.findings)
        }

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

    /// Act on `scenario` and observe what changed.
    ///
    /// The act-then-observe loop is the tightest one an agent runs, and this is
    /// the single call that closes it: capture, act, settle, capture, diff, lint.
    ///
    /// Delegates to ``Harness/perform(_:timeout:)`` rather than reimplementing
    /// the sequence, for the reason every method here delegates — the CLI, the
    /// socket daemon and the MCP server must not be able to disagree about what
    /// acting means. `perform` also never throws for a settle timeout or an
    /// unknown probe: both come back as a FAILING ``StepResult`` with cited
    /// evidence, so the only errors escaping here are the ones that mean the
    /// engine could not look at all.
    @MainActor
    public func act(
        scenario name: String,
        action: ProbeAction,
        rules: [any LintRule] = RuleEngine.standardRules,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        includeTree: Bool = false
    ) async throws -> StepResult {
        let entry = try entry(named: name)
        let harness = Harness(
            host: entry.host(viewport: viewport, deadline: deadline),
            rules: rules,
            includeTree: includeTree
        )
        return await harness.perform(action)
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

    // MARK: - Cross-validation (Wave 8)

    /// Reconcile `tree` against the external witness, or say why not.
    ///
    /// Never throws and never returns silence: a witness that could not run
    /// yields exactly one `cross-validation-skipped` warning naming the reason.
    /// A caller that ASKED for cross-validation and got an ordinary PASS would
    /// read it as "both channels agree" when only one channel ran, which is the
    /// distinction the whole wave exists to preserve.
    @MainActor
    static func crossValidationFindings(for scenario: String, tree: SemanticNode) -> [Finding] {
        guard let executable = witnessHostExecutable() else {
            return [
                Reconcile.unavailable(
                    reason: "the verdictui-witness-host executable was not found next to the "
                        + "verdictui binary; build it with `swift build`")
            ]
        }
        let witness = WitnessHostProcess(executable: executable)
        return CrossValidation.findings(internalTree: tree) {
            try witness.readTree(scenario: scenario)
        }
    }

    /// Locate `verdictui-witness-host` beside the running executable.
    ///
    /// Beside the BINARY rather than relative to the working directory: a CLI
    /// is run from wherever the user happens to be, and a cwd-relative lookup
    /// would find the host only when invoked from the package root — working in
    /// every test and failing for every real caller.
    static func witnessHostExecutable() -> URL? {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = binary.deletingLastPathComponent()
            .appendingPathComponent("verdictui-witness-host")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
